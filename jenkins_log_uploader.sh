#!/bin/bash

# ----------- CONFIGURABLE VARIABLES -------------
JOB_LIST=("job-one" "job-two" "job-three")  # Your Jenkins jobs
S3_BUCKET="your-s3-bucket-name"
S3_FOLDER="jenkins-logs"
JENKINS_LOG_DIR="/var/lib/jenkins/jobs"
MANIFEST_FILE="./jenkins_log_manifest.csv"
PARALLEL_UPLOAD=true
# -----------------------------------------------

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    echo "AWS CLI is not installed. Please install it first:"
    echo "https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html"
    exit 1
fi

# Create manifest file if missing
if [ ! -f "$MANIFEST_FILE" ]; then
    echo "Job Name,Build Number,Log Date,S3 Path,Status" > "$MANIFEST_FILE"
fi

upload_log() {
    local job="$1"
    local build="$2"
    local log_file="${JENKINS_LOG_DIR}/${job}/builds/${build}/log"

    # Check if log file exists
    if [ ! -f "$log_file" ]; then
        echo "Missing log for $job build $build"
        return
    fi

    # Check if log file was created today
    local today=$(date +%Y-%m-%d)
    local file_date=$(date -r "$log_file" +%Y-%m-%d)
    if [ "$file_date" != "$today" ]; then
        echo "Skipping: $job build $build (log date $file_date)"
        echo "${job},${build},${file_date},N/A,SKIPPED (Old log)" >> "$MANIFEST_FILE"
        return
    fi

    # Prepare S3 key
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local s3_object="${S3_FOLDER}/${job}/build_${build}_${timestamp}.log"

    # Skip if log already exists in S3
    aws s3 ls "s3://${S3_BUCKET}/${s3_object}" > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo "Already uploaded: $job build $build"
        echo "${job},${build},${file_date},${s3_object},SKIPPED (Exists)" >> "$MANIFEST_FILE"
        return
    fi

    # Upload log
    echo "Uploading: $job build $build log..."
    aws s3 cp "$log_file" "s3://${S3_BUCKET}/${s3_object}" --acl private
    if [ $? -eq 0 ]; then
        echo "Success: $job build $build"
        echo "${job},${build},${file_date},${s3_object},SUCCESS" >> "$MANIFEST_FILE"
    else
        echo "Failure: $job build $build"
        echo "${job},${build},${file_date},${s3_object},FAILED" >> "$MANIFEST_FILE"
    fi
}

process_job() {
    local job="$1"
    local build_dir="${JENKINS_LOG_DIR}/${job}/builds"

    if [ ! -d "$build_dir" ]; then
        echo "No build directory for job: $job"
        return
    fi

    for build in $(ls "$build_dir" | grep -E '^[0-9]+$'); do
        if $PARALLEL_UPLOAD; then
            upload_log "$job" "$build" &
        else
            upload_log "$job" "$build"
        fi
    done
}

# Main loop
for job in "${JOB_LIST[@]}"; do
    echo "Scanning job: $job"
    process_job "$job"
done

# Wait for background jobs if enabled
wait
echo "Upload complete. See manifest: $MANIFEST_FILE"
