
#!/usr/bin/env bash
# ssm-set-delayed-auto.sh
# Run from AWS CloudShell. Discovers SSM HYBRID (mi-) Windows instances,
# runs "sc.exe config AmazonSSMAgent start=delayed-auto" on each via
# SSM Run Command (AWS-RunPowerShellScript), collects results, and
# builds a consolidated HTML report uploaded to S3 (partitioned YYYY/MM/DD/HH in IST).
#
# Usage:
#   ./ssm-set-delayed-auto.sh mi-0abc123...            -> ONE instance (test)
#   ./ssm-set-delayed-auto.sh mi-0abc... mi-0def...    -> selected instances
#   ./ssm-set-delayed-auto.sh --all                    -> ALL online instances (asks to confirm)
#   ./ssm-set-delayed-auto.sh --all --yes              -> ALL, no prompt

set -uo pipefail
export AWS_RETRY_MODE=adaptive
export AWS_MAX_ATTEMPTS=10

# ---------------- CONFIG ----------------
S3_BUCKET="devops-deployment-artifact"
S3_PREFIX="nap-ssm-delayed-auto"
REGION="ap-south-1"
ONLINE_ONLY=true
WINDOWS_ONLY=true
TARGET_IDS=""
CHUNK=50
WAIT_SECONDS=300
POLL_INTERVAL=5
EXEC_TIMEOUT=120
# ----------------------------------------

# ---- Usage / target selection ----
usage() { sed -n '/^# Usage/,/^#   .*--yes/p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
RUN_ALL=false; ASSUME_YES=false
[[ $# -eq 0 ]] && usage
for a in "$@"; do
    case "$a" in
        --all) RUN_ALL=true ;;
        --yes|-y) ASSUME_YES=true ;;
        mi-*|i-*) TARGET_IDS="${TARGET_IDS} $a" ;;
        *) echo "!! Unknown argument: $a"; usage ;;
    esac
done
if [[ "${RUN_ALL}" == "true" && -n "${TARGET_IDS// }" ]]; then
    echo "!! Use either --all or instance id(s), not both."; exit 1
fi

TS="$(TZ='Asia/Kolkata' date +%Y%m%d-%H%M%S)"
YEAR="${TS:0:4}"; MONTH="${TS:4:2}"; DAY="${TS:6:2}"; HOUR="${TS:9:2}"
WORKDIR="$(mktemp -d)"
META_JSON="${WORKDIR}/ssm-metadata.json"
REPORT_HTML="${WORKDIR}/SSM-DelayedAuto-Report-${TS}.html"
OUT_S3_PREFIX="${S3_PREFIX}/ssm-output/${TS}"
mkdir -p "${WORKDIR}/out" "${WORKDIR}/hosts"

# ---- 0. Discover hybrid instances (manual pagination, throttle-safe) ----
echo ">> Discovering hybrid (mi-) instances..."
FILTERS=(Key=ResourceType,Values=ManagedInstance)
[[ "${WINDOWS_ONLY}" == "true" ]] && FILTERS+=(Key=PlatformTypes,Values=Windows)
[[ "${ONLINE_ONLY}"  == "true" ]] && FILTERS+=(Key=PingStatus,Values=Online)

echo "[]" > "${META_JSON}"
NEXT=""
while :; do
    ARGS=(--region "${REGION}" --filters "${FILTERS[@]}" --max-items 50 --page-size 50 --output json)
    [[ -n "${NEXT}" ]] && ARGS+=(--starting-token "${NEXT}")
    PAGE=$(aws ssm describe-instance-information "${ARGS[@]}") || { echo "!! describe-instance-information failed"; exit 1; }
    echo "${PAGE}" | jq '[.InstanceInformationList[] | {InstanceId,ComputerName,PlatformName,PlatformVersion,PingStatus}]' \
        | jq -s '.[0] + .[1]' "${META_JSON}" - > "${META_JSON}.tmp" && mv "${META_JSON}.tmp" "${META_JSON}"
    NEXT=$(echo "${PAGE}" | jq -r '.NextToken // empty')
    [[ -z "${NEXT}" ]] && break
    sleep 1
done

if [[ -n "${TARGET_IDS}" ]]; then
    INSTANCE_IDS="${TARGET_IDS}"
    for id in ${INSTANCE_IDS}; do
        jq -e --arg i "$id" 'any(.[]; .InstanceId==$i)' "${META_JSON}" >/dev/null \
            || echo "   WARN: ${id} not in Online/Windows hybrid list (offline or wrong id) - will still try"
    done
else
    INSTANCE_IDS=$(jq -r '.[].InstanceId' "${META_JSON}")
fi
IDS_ARR=(${INSTANCE_IDS})
COUNT=${#IDS_ARR[@]}
[[ ${COUNT} -eq 0 ]] && { echo "!! No instances found."; exit 1; }
echo ">> ${COUNT} instance(s) targeted ($([[ ${RUN_ALL} == true ]] && echo 'ALL instances' || echo 'selected'))."
if [[ "${RUN_ALL}" == "true" && "${ASSUME_YES}" != "true" ]]; then
    read -r -p ">> Run sc.exe config on ALL ${COUNT} instances? Type YES to continue: " ANS
    [[ "${ANS}" == "YES" ]] || { echo "Aborted."; exit 0; }
fi

# ---- 1. The command to run on each instance ----
# Runs sc.exe, captures exit code, and outputs structured JSON between markers
# so we can reliably parse results from S3 command output.
read -r -d '' PS_COMMAND <<'PSEOF' || true
$ErrorActionPreference = 'Stop'
$result = [ordered]@{
    HostName    = $env:COMPUTERNAME
    CollectedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Command     = 'sc.exe config AmazonSSMAgent start=delayed-auto'
    ExitCode    = -1
    Output      = ''
    Error       = ''
}
try {
    $proc = Start-Process -FilePath 'sc.exe' `
        -ArgumentList 'config','AmazonSSMAgent','start=delayed-auto' `
        -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput "$env:TEMP\sc_stdout.txt" `
        -RedirectStandardError  "$env:TEMP\sc_stderr.txt"
    $result.ExitCode = $proc.ExitCode
    $result.Output   = (Get-Content "$env:TEMP\sc_stdout.txt" -Raw -ErrorAction SilentlyContinue) -replace '\s+$',''
    $result.Error    = (Get-Content "$env:TEMP\sc_stderr.txt" -Raw -ErrorAction SilentlyContinue) -replace '\s+$',''
    Remove-Item "$env:TEMP\sc_stdout.txt","$env:TEMP\sc_stderr.txt" -Force -ErrorAction SilentlyContinue

    # Verify the change took effect
    $svc = Get-WmiObject Win32_Service -Filter "Name='AmazonSSMAgent'" -ErrorAction SilentlyContinue
    if ($svc) {
        $result['StartMode'] = $svc.StartMode
    }
} catch {
    $result.Error = $_.Exception.Message
}
Write-Output '###JSON_BEGIN###'
Write-Output ([PSCustomObject]$result | ConvertTo-Json -Depth 3 -Compress)
Write-Output '###JSON_END###'
PSEOF

# ---- 2. Send in batches via AWS-RunPowerShellScript ----
echo ">> Sending SSM command (sc.exe config AmazonSSMAgent start=delayed-auto)..."
ALL_CMD_IDS=()
for ((i=0; i<COUNT; i+=CHUNK)); do
    BATCH=("${IDS_ARR[@]:i:CHUNK}")
    CMD_ID=$(aws ssm send-command --region "${REGION}" \
        --document-name "AWS-RunPowerShellScript" \
        --instance-ids "${BATCH[@]}" \
        --comment "Set AmazonSSMAgent start=delayed-auto (${TS})" \
        --parameters "{\"commands\":[$(echo "${PS_COMMAND}" | jq -Rs '.')],\"executionTimeout\":[\"${EXEC_TIMEOUT}\"]}" \
        --output-s3-bucket-name "${S3_BUCKET}" --output-s3-key-prefix "${OUT_S3_PREFIX}" \
        --max-concurrency "50" --max-errors "100%" \
        --query "Command.CommandId" --output text) || { echo "   batch $((i/CHUNK+1)): send-command FAILED, skipping"; continue; }
    echo "   batch $((i/CHUNK+1)): ${CMD_ID} (${#BATCH[@]} instances)"
    ALL_CMD_IDS+=("${CMD_ID}")
done

# ---- 3. Wait per batch with hard timeout ----
echo ">> Waiting (max ${WAIT_SECONDS}s per batch)..."
for CMD_ID in "${ALL_CMD_IDS[@]}"; do
    START=$(date +%s)
    while :; do
        STATES=$(aws ssm list-command-invocations --region "${REGION}" --command-id "${CMD_ID}" \
            --query "CommandInvocations[].Status" --output text 2>/dev/null || true)
        if [[ -n "${STATES}" ]] && ! echo "${STATES}" | grep -Eq "Pending|InProgress|Delayed"; then break; fi
        if (( $(date +%s) - START >= WAIT_SECONDS )); then
            P=$(echo "${STATES}" | tr '\t' '\n' | grep -Ec "Pending|InProgress|Delayed" || true)
            echo "   ${CMD_ID}: timeout, skipping ${P} unfinished node(s)"; break
        fi
        sleep "${POLL_INTERVAL}"
    done
done

# ---- 4. Collect: statuses from API, full stdout from S3 ----
echo ">> Collecting results..."
aws s3 cp "s3://${S3_BUCKET}/${OUT_S3_PREFIX}/" "${WORKDIR}/out/" --recursive --region "${REGION}" --quiet || true

for CMD_ID in "${ALL_CMD_IDS[@]}"; do
    aws ssm list-command-invocations --region "${REGION}" --command-id "${CMD_ID}" \
        --query "CommandInvocations[].[InstanceId,Status]" --output text 2>/dev/null |
    while read -r IID STATUS; do
        [[ -z "${IID}" ]] && continue
        OUTFILE=$(find "${WORKDIR}/out/${CMD_ID}/${IID}" -type f -name stdout 2>/dev/null | xargs -r grep -l '###JSON_BEGIN###' 2>/dev/null | head -n1)
        HOSTJSON=""
        [[ -n "${OUTFILE}" ]] && HOSTJSON=$(sed -n '/###JSON_BEGIN###/,/###JSON_END###/p' "${OUTFILE}" | grep -v '###JSON_' | tr -d '\r')
        if [[ -n "${HOSTJSON}" ]] && echo "${HOSTJSON}" | jq -e . >/dev/null 2>&1; then
            echo "${HOSTJSON}" | jq --arg iid "$IID" --arg st "$STATUS" '. + {InstanceId:$iid, InvocationStatus:$st}' \
                > "${WORKDIR}/hosts/${IID}.json"
        else
            ERR=$(find "${WORKDIR}/out/${CMD_ID}/${IID}" -type f -name stderr 2>/dev/null | head -n1 | xargs -r head -c 500 2>/dev/null || true)
            jq -n --arg iid "$IID" --arg st "$STATUS" --arg e "${ERR:-No output (offline / pending / script failed)}" \
                '{InstanceId:$iid, InvocationStatus:$st, HostName:"", ExitCode:-1, Output:"", Error:$e, StartMode:""}' \
                > "${WORKDIR}/hosts/${IID}.json"
        fi
    done
done

RESULTS_JSON="${WORKDIR}/results.json"
if ls "${WORKDIR}"/hosts/*.json >/dev/null 2>&1; then
    jq -s '.' "${WORKDIR}"/hosts/*.json > "${RESULTS_JSON}"
else
    echo "[]" > "${RESULTS_JSON}"
fi

# ---- 5. Build HTML report ----
echo ">> Building HTML report..."
python3 - "$RESULTS_JSON" "$META_JSON" "$REPORT_HTML" "$TS" <<'PYEOF'
import json, sys, html
res_p, meta_p, out_p, ts = sys.argv[1:5]
data = json.load(open(res_p)); meta = json.load(open(meta_p))
mm = {m["InstanceId"]: m for m in meta}
e = lambda x: html.escape(str(x if x is not None else ""))

for h in data:
    m = mm.get(h["InstanceId"], {})
    h["_Name"] = m.get("ComputerName") or h.get("HostName") or ""
    h["_OS"] = " ".join(x for x in [m.get("PlatformName"), m.get("PlatformVersion")] if x)
    ec = h.get("ExitCode", -1)
    sm = h.get("StartMode", "")
    if ec == 0 and sm in ("Auto", "Automatic"):
        h["_result"] = "OK - Delayed-Auto"
    elif ec == 0:
        h["_result"] = f"OK (ExitCode=0, StartMode={sm or 'unknown'})"
    else:
        h["_result"] = "FAILED"

data.sort(key=lambda h: (0 if h["_result"].startswith("OK") else 1, h["_Name"].upper()))

ok   = [h for h in data if h.get("ExitCode", -1) == 0 and h.get("InvocationStatus") == "Success"]
fail = [h for h in data if h not in ok]

summ = ""
for h in data:
    cls = "ok" if h in ok else "err"
    summ += (f"<tr><td>{e(h['_Name'] or '(unknown)')}</td><td>{e(h['InstanceId'])}</td>"
             f"<td>{e(h['_OS'])}</td><td class='{cls}'>{e(h.get('InvocationStatus'))}</td>"
             f"<td>{e(h.get('ExitCode'))}</td><td>{e(h.get('StartMode'))}</td>"
             f"<td class='{cls}'>{e(h['_result'])}</td>"
             f"<td>{e(h.get('Output'))}</td>"
             f"<td class='errtxt'>{e(h.get('Error'))}</td></tr>\n")

doc = f"""<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
<title>SSM Agent Delayed-Auto Config Report</title>
<style>
 body{{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#232f3e;background:#f7f8fa;}}
 h1{{font-size:22px;}} h2{{font-size:17px;border-bottom:2px solid #ff9900;padding-bottom:4px;margin-top:28px;}}
 .cards{{display:flex;gap:16px;margin:16px 0;flex-wrap:wrap;}}
 .card{{background:#fff;border:1px solid #ddd;border-left:4px solid #ff9900;border-radius:6px;padding:14px 18px;min-width:150px;}}
 .card.alert{{border-left-color:#d13212;}}
 .card .n{{font-size:26px;font-weight:700;}} .card .l{{color:#555;font-size:12px;}}
 table{{border-collapse:collapse;width:100%;background:#fff;margin-top:6px;}}
 th,td{{border:1px solid #ddd;padding:6px 8px;text-align:left;font-size:12.5px;vertical-align:top;}}
 th{{background:#232f3e;color:#fff;position:sticky;top:0;}}
 .ok{{color:#1a7f37;font-weight:600;}} .err{{color:#c00;font-weight:600;}}
 .errtxt{{color:#c00;font-size:11.5px;}} .ts{{color:#555;font-size:12px;}}
</style></head><body>
<h1>SSM Agent &mdash; Set Startup to Delayed-Auto</h1>
<p class="ts">Generated (IST): {e(ts)} &nbsp;|&nbsp; Command: <code>sc.exe config AmazonSSMAgent start=delayed-auto</code></p>
<div class="cards">
 <div class="card"><div class="n">{len(data)}</div><div class="l">Instances targeted</div></div>
 <div class="card"><div class="n">{len(ok)}</div><div class="l">Succeeded</div></div>
 <div class="card alert"><div class="n">{len(fail)}</div><div class="l">Failed / no output</div></div>
</div>
<h2>Results by Instance</h2>
<table><tr><th>Server</th><th>Instance ID</th><th>OS</th><th>SSM Status</th><th>Exit Code</th><th>Start Mode</th><th>Result</th><th>sc.exe Output</th><th>Error</th></tr>
{summ}</table>
</body></html>"""
open(out_p, "w").write(doc)
print(f"HTML written: {out_p}")
PYEOF

# ---- 6. Upload ----
S3_KEY="${S3_PREFIX}/${YEAR}/${MONTH}/${DAY}/${HOUR}/SSM-DelayedAuto-Report-${TS}.html"
aws s3 cp "${REPORT_HTML}" "s3://${S3_BUCKET}/${S3_KEY}" --region "${REGION}" --content-type "text/html"
aws s3 cp "${RESULTS_JSON}" "s3://${S3_BUCKET}/${S3_PREFIX}/${YEAR}/${MONTH}/${DAY}/${HOUR}/SSM-DelayedAuto-${TS}.json" --region "${REGION}" --quiet

echo ""
echo ">> DONE. Instances: $(jq 'length' "${RESULTS_JSON}") | OK: $(jq '[.[]|select(.InvocationStatus=="Success" and (.ExitCode==0))]|length' "${RESULTS_JSON}")"
echo ">> Report: s3://${S3_BUCKET}/${S3_KEY}"
aws s3 presign "s3://${S3_BUCKET}/${S3_KEY}" --region "${REGION}" --expires-in 3600

# Cleanup
rm -rf "${WORKDIR}"

