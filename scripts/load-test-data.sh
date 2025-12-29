#!/bin/bash
# =============================================================================
# DICOM Web Viewer Stack - Load Test Data Script
# =============================================================================
# Downloads sample DICOM data and places it in inbox folders for testing
# =============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Load environment
if [[ -f "$PROJECT_DIR/.env" ]]; then
    source "$PROJECT_DIR/.env"
fi

# Configuration
INBOX_PATH="${INBOX_PATH:-$PROJECT_DIR/data/inbox}"
TEMP_DIR=$(mktemp -d)

# Sample DICOM sources (public datasets)
# Using NEMA sample files and other public sources
SAMPLE_SOURCES=(
    # NEMA sample files
    "https://raw.githubusercontent.com/pydicom/pydicom/main/tests/data/test_files/CT_small.dcm"
    "https://raw.githubusercontent.com/pydicom/pydicom/main/tests/data/test_files/MR_small.dcm"
)

# Log functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Show usage
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --clinic CLINIC_ID   Target clinic for test data (default: denscan-central)"
    echo "  --count N            Number of test studies to create (default: 3)"
    echo "  --no-download        Don't download, just create dummy files"
    echo "  -h, --help           Show this help message"
    exit 0
}

# Parse arguments
TARGET_CLINIC="denscan-central"
STUDY_COUNT=3
DOWNLOAD=true

while [[ $# -gt 0 ]]; do
    case $1 in
        --clinic)
            TARGET_CLINIC="$2"
            shift 2
            ;;
        --count)
            STUDY_COUNT="$2"
            shift 2
            ;;
        --no-download)
            DOWNLOAD=false
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Download sample DICOM files
download_samples() {
    log_info "Downloading sample DICOM files..."

    mkdir -p "$TEMP_DIR/samples"

    local count=0
    for url in "${SAMPLE_SOURCES[@]}"; do
        local filename=$(basename "$url")
        log_info "  Downloading: $filename"

        if curl -sL "$url" -o "$TEMP_DIR/samples/$filename" 2>/dev/null; then
            ((count++))
        else
            log_warn "  Failed to download: $url"
        fi
    done

    if [[ $count -eq 0 ]]; then
        log_warn "No samples downloaded, will create synthetic files"
        return 1
    fi

    log_success "Downloaded $count sample files"
    return 0
}

# Create synthetic DICOM file using Python/pydicom
create_synthetic_dicom() {
    local output_file="$1"
    local patient_name="$2"
    local study_date="$3"
    local modality="${4:-CT}"

    python3 << EOF
import sys
try:
    from pydicom.dataset import Dataset, FileDataset
    from pydicom.uid import ExplicitVRLittleEndian, generate_uid
    import numpy as np
    from datetime import datetime
    import os

    # Create file meta
    file_meta = Dataset()
    file_meta.MediaStorageSOPClassUID = '1.2.840.10008.5.1.4.1.1.2'  # CT Image Storage
    file_meta.MediaStorageSOPInstanceUID = generate_uid()
    file_meta.TransferSyntaxUID = ExplicitVRLittleEndian
    file_meta.ImplementationClassUID = generate_uid()

    # Create dataset
    ds = FileDataset(None, {}, file_meta=file_meta, preamble=b'\x00' * 128)

    # Patient info
    ds.PatientName = "$patient_name"
    ds.PatientID = "TEST" + generate_uid()[-8:]
    ds.PatientBirthDate = "19800101"
    ds.PatientSex = "O"

    # Study info
    ds.StudyDate = "$study_date"
    ds.StudyTime = "120000"
    ds.StudyDescription = "Test Study"
    ds.StudyInstanceUID = generate_uid()
    ds.StudyID = "TEST001"
    ds.AccessionNumber = "ACC" + generate_uid()[-6:]

    # Series info
    ds.SeriesDate = "$study_date"
    ds.SeriesTime = "120000"
    ds.SeriesDescription = "Test Series"
    ds.SeriesInstanceUID = generate_uid()
    ds.SeriesNumber = 1
    ds.Modality = "$modality"

    # Instance info
    ds.SOPClassUID = file_meta.MediaStorageSOPClassUID
    ds.SOPInstanceUID = file_meta.MediaStorageSOPInstanceUID
    ds.InstanceNumber = 1

    # Image info
    ds.Rows = 64
    ds.Columns = 64
    ds.BitsAllocated = 16
    ds.BitsStored = 12
    ds.HighBit = 11
    ds.PixelRepresentation = 0
    ds.SamplesPerPixel = 1
    ds.PhotometricInterpretation = "MONOCHROME2"
    ds.PixelData = np.random.randint(0, 4096, (64, 64), dtype=np.uint16).tobytes()

    # Required flags
    ds.is_little_endian = True
    ds.is_implicit_VR = False

    # Save
    ds.save_as("$output_file")
    print("Created: $output_file")

except ImportError:
    print("pydicom not available, skipping synthetic file creation")
    sys.exit(1)
except Exception as e:
    print(f"Error: {e}")
    sys.exit(1)
EOF
}

# Create test study folder
create_test_study() {
    local study_num="$1"
    local clinic="$2"

    local patient_names=("Smith^John" "Johnson^Mary" "Williams^Robert" "Brown^Patricia" "Jones^Michael")
    local modalities=("CT" "MR" "CR" "DX")

    local patient_name="${patient_names[$((study_num % ${#patient_names[@]}))]}"
    local modality="${modalities[$((study_num % ${#modalities[@]}))]}"
    local study_date=$(date -d "-$study_num days" +%Y%m%d 2>/dev/null || date +%Y%m%d)

    local study_folder="$INBOX_PATH/$clinic/${patient_name//^/_}_${study_date}"

    log_info "Creating study: $study_folder"
    mkdir -p "$study_folder"

    # Create multiple slices
    for slice in $(seq 1 5); do
        local dcm_file="$study_folder/slice_$(printf "%03d" $slice).dcm"

        if [[ "$DOWNLOAD" == "true" ]] && [[ -d "$TEMP_DIR/samples" ]] && [[ -n "$(ls -A $TEMP_DIR/samples 2>/dev/null)" ]]; then
            # Use downloaded sample
            local sample=$(ls "$TEMP_DIR/samples"/*.dcm 2>/dev/null | head -1)
            if [[ -n "$sample" ]]; then
                cp "$sample" "$dcm_file"
                log_info "  Copied sample to: slice_$(printf "%03d" $slice).dcm"
            fi
        else
            # Create synthetic
            if command -v python3 &> /dev/null; then
                create_synthetic_dicom "$dcm_file" "$patient_name" "$study_date" "$modality" 2>/dev/null || \
                    log_warn "  Could not create synthetic DICOM (pydicom may not be installed)"
            fi
        fi
    done

    log_success "Study created: ${patient_name//^/ } ($modality)"
}

# Cleanup
cleanup() {
    log_info "Cleaning up temporary files..."
    rm -rf "$TEMP_DIR"
}

trap cleanup EXIT

# Main function
main() {
    echo "=============================================="
    echo "  Loading Test Data"
    echo "=============================================="
    echo ""
    echo "Target clinic: $TARGET_CLINIC"
    echo "Study count: $STUDY_COUNT"
    echo "Inbox path: $INBOX_PATH"
    echo ""

    # Check inbox path exists
    if [[ ! -d "$INBOX_PATH/$TARGET_CLINIC" ]]; then
        log_warn "Creating inbox folder for clinic: $TARGET_CLINIC"
        mkdir -p "$INBOX_PATH/$TARGET_CLINIC"
    fi

    # Try to download samples
    if [[ "$DOWNLOAD" == "true" ]]; then
        download_samples || true
    fi

    # Create test studies
    log_info "Creating $STUDY_COUNT test studies..."
    for i in $(seq 1 $STUDY_COUNT); do
        create_test_study "$i" "$TARGET_CLINIC"
    done

    echo ""
    echo "=============================================="
    log_success "Test data loaded!"
    echo "=============================================="
    echo ""
    echo "Files placed in: $INBOX_PATH/$TARGET_CLINIC/"
    echo ""
    echo "If the importer service is running, files will be"
    echo "automatically imported after the cooldown period."
    echo ""
    echo "To check import status:"
    echo "  docker compose logs -f importer"
    echo ""
}

# Run main function
main "$@"
