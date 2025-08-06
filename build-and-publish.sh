#!/bin/bash

# Crossplane Provider SQL - Build and Publish Script
# This script builds both AMD64 and ARM64 architectures and publishes to ECR

set -euo pipefail

# Configuration
VERSION="${VERSION:-v0.12.0}"
ECR_REGISTRY="${ECR_REGISTRY:-611542441284.dkr.ecr.us-east-1.amazonaws.com}"
ECR_REPOSITORY="${ECR_REPOSITORY:-crossplane-sql-provider}"
AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_PROFILE="${AWS_PROFILE:-mgmt}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check if we're in the right directory
    if [[ ! -f "go.mod" ]] || [[ ! -f "Makefile" ]]; then
        log_error "Please run this script from the provider-sql root directory"
        exit 1
    fi
    
    # Check required tools
    local missing_tools=()
    
    if ! command -v make &> /dev/null; then
        missing_tools+=("make")
    fi
    
    if ! command -v docker &> /dev/null; then
        missing_tools+=("docker")
    fi
    
    if ! command -v aws &> /dev/null; then
        missing_tools+=("aws")
    fi
    
    if [[ ${#missing_tools[@]} -ne 0 ]]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        exit 1
    fi
    
    log_success "All prerequisites met"
}

# Download up CLI if not available
setup_up_cli() {
    log_info "Setting up up CLI..."
    
    if [[ ! -f "/tmp/up" ]]; then
        log_info "Downloading up CLI..."
        local arch="arm64"
        if [[ "$(uname -m)" == "x86_64" ]]; then
            arch="amd64"
        fi
        
        curl -sL "https://cli.upbound.io/stable/v0.28.0/bin/darwin_${arch}/up" -o /tmp/up
        chmod +x /tmp/up
        log_success "up CLI downloaded to /tmp/up"
    else
        log_info "up CLI already available at /tmp/up"
    fi
}

# Clean previous builds
clean_build() {
    log_info "Cleaning previous build artifacts..."
    
    make clean || true
    rm -rf _output || true
    
    # Clean Docker images from previous builds
    docker images --filter "reference=build-*/provider-sql-*" --format "table {{.Repository}}:{{.Tag}}" | grep -v REPOSITORY | while read image; do
        if [[ -n "$image" ]]; then
            log_info "Removing Docker image: $image"
            docker rmi "$image" --force 2>/dev/null || true
        fi
    done
    
    log_success "Clean completed"
}

# Update git submodules
update_submodules() {
    log_info "Updating git submodules..."
    git submodule update --init --recursive
    log_success "Submodules updated"
}

# Build binaries and xpkg packages
build_packages() {
    log_info "Building binaries and xpkg packages for version $VERSION..."
    
    # Build all architectures and create xpkg packages
    make build.all xpkg.build VERSION="$VERSION"
    
    log_success "Build completed"
    
    # Verify the packages were created
    if [[ -f "_output/xpkg/linux_amd64/provider-sql-${VERSION}.xpkg" ]] && [[ -f "_output/xpkg/linux_arm64/provider-sql-${VERSION}.xpkg" ]]; then
        log_success "Both AMD64 and ARM64 packages created successfully"
        ls -la _output/xpkg/*/provider-sql-${VERSION}.xpkg
    else
        log_error "Failed to create xpkg packages"
        exit 1
    fi
}

# Login to AWS ECR
aws_ecr_login() {
    log_info "Logging into AWS ECR..."
    
    aws ecr get-login-password --region "$AWS_REGION" --profile "$AWS_PROFILE" | \
        docker login --username AWS --password-stdin "$ECR_REGISTRY"
    
    log_success "Successfully logged into ECR"
}

# Push xpkg packages to ECR
push_packages() {
    log_info "Pushing xpkg packages to ECR..."
    
    local full_repo="$ECR_REGISTRY/$ECR_REPOSITORY"
    
    # Push AMD64 package
    log_info "Pushing AMD64 package..."
    /tmp/up xpkg push --package "_output/xpkg/linux_amd64/provider-sql-${VERSION}.xpkg" \
        "$full_repo:${VERSION}-amd64"
    log_success "AMD64 package pushed"
    
    # Push ARM64 package
    log_info "Pushing ARM64 package..."
    /tmp/up xpkg push --package "_output/xpkg/linux_arm64/provider-sql-${VERSION}.xpkg" \
        "$full_repo:${VERSION}-arm64"
    log_success "ARM64 package pushed"
}

# Create and push multi-architecture manifest
create_multiarch_manifest() {
    log_info "Creating multi-architecture manifest..."
    
    local full_repo="$ECR_REGISTRY/$ECR_REPOSITORY"
    
    # Remove existing manifest if it exists
    docker manifest rm "$full_repo:$VERSION" 2>/dev/null || true
    
    # Create multi-arch manifest
    docker manifest create "$full_repo:$VERSION" \
        "$full_repo:${VERSION}-amd64" \
        "$full_repo:${VERSION}-arm64"
    
    # Push the manifest
    docker manifest push "$full_repo:$VERSION"
    
    log_success "Multi-architecture manifest created and pushed"
    
    # Verify the manifest
    log_info "Verifying multi-architecture manifest..."
    docker manifest inspect "$full_repo:$VERSION"
}



# Main execution
main() {
    log_info "Starting Crossplane Provider SQL build and publish process..."
    log_info "Version: $VERSION"
    log_info "Registry: $ECR_REGISTRY"
    log_info "Repository: $ECR_REPOSITORY"
    echo ""
    
    check_prerequisites
    setup_up_cli
    clean_build
    update_submodules
    build_packages
    aws_ecr_login
    push_packages
    create_multiarch_manifest
    
    echo ""
    log_success "🎉 Build and publish completed successfully!"
    echo ""
    log_info "Next steps:"
    log_info "1. Apply the provider to your Crossplane cluster:"
    log_info "   kubectl apply -f install-provider.yaml"
    echo ""
    log_info "2. Create and apply your database credentials secret"
    echo ""
    log_info "3. Verify the provider is running:"
    log_info "   kubectl get providers"
    log_info "   kubectl get pods -n crossplane-system"
    echo ""
}

# Handle script arguments
case "${1:-}" in
    --help|-h)
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Environment variables:"
        echo "  VERSION       Provider version (default: v0.12.0)"
        echo "  ECR_REGISTRY  ECR registry URL (default: 611542441284.dkr.ecr.us-east-1.amazonaws.com)"
        echo "  ECR_REPOSITORY ECR repository name (default: crossplane-sql-provider)"
        echo "  AWS_REGION    AWS region (default: us-east-1)"
        echo "  AWS_PROFILE   AWS profile (default: mgmt)"
        echo ""
        echo "Example:"
        echo "  VERSION=v0.13.0 ECR_REPOSITORY=my-sql-provider $0"
        exit 0
        ;;
    *)
        main "$@"
        ;;
esac
