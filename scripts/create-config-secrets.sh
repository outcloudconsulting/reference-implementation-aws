#!/bin/bash
set -e -o pipefail

export REPO_ROOT=$(git rev-parse --show-toplevel)
SECRET_NAME_PREFIX="cnoe-ref-impl"
PHASE="create-update-secrets"
source ${REPO_ROOT}/scripts/utils.sh

PRIVATE_DIR="$REPO_ROOT/private"

echo -e "\n${BOLD}${BLUE}🔐 Starting secret creation process...${NC}"
echo -e "${CYAN}📂 Reading files from:${NC} ${BOLD}${PRIVATE_DIR}${NC}"

if [ ! -d "$PRIVATE_DIR" ]; then
    echo -e "${RED}❌ Directory $PRIVATE_DIR does not exist${NC}"
    exit 1
fi

# control whether to store in AWS Secrets Manager and/or Kubernetes
USE_AWS_SECRETS=$(yq -r '.secrets.use_aws // "false"' "$CONFIG_FILE")
USE_K8S_SECRETS=$(yq -r '.secrets.use_k8s // "true"' "$CONFIG_FILE")

# If we need to create k8s secrets, prepare a kubeconfig
if [ "$USE_K8S_SECRETS" = "true" ]; then
  # prefer local admin.conf if present (useful when running on control-plane host)
  if [ -f /var/lib/k0s/pki/admin.conf ]; then
    echo -e "${PURPLE}📍 Preparing local kubeconfig from /var/lib/k0s/pki/admin.conf${NC}"
    KUBECONFIG_FILE=$(mktemp)
    sudo cp /var/lib/k0s/pki/admin.conf "$KUBECONFIG_FILE"
    sudo chown $(id -u):$(id -g) "$KUBECONFIG_FILE"
    export KUBECONFIG_FILE
  elif type get_kubeconfig >/dev/null 2>&1; then
    echo -e "${PURPLE}🔑 Fetching kubeconfig using get_kubeconfig()${NC}"
    get_kubeconfig
    # get_kubeconfig must set KUBECONFIG_FILE
    if [ -z "$KUBECONFIG_FILE" ]; then
      echo -e "${RED}❌ get_kubeconfig() did not set KUBECONFIG_FILE${NC}"
      exit 1
    fi
  else
    echo -e "${RED}❌ No admin.conf found and get_kubeconfig() unavailable${NC}"
    exit 1
  fi
fi

# Create or update secret
create_update_secret() {
    name="$1"
    file="$2"

    echo -e "\n${PURPLE}🚀 Processing Secret for ${name}...${NC}"

   # AWS Secrets Manager path
   if [ "$USE_AWS_SECRETS" = "true" ]; then
     TAGS=$(get_tags_from_config)
     if aws secretsmanager create-secret \
        --name "$SECRET_NAME_PREFIX/$name" \
        --secret-string file://"$file" \
        --description "Secret created for $name of CNOE AWS Reference Implementation" \
        --tags $TAGS \
        --region $AWS_REGION >/dev/null 2>&1; then
        echo -e "${GREEN}✅ AWS Secret '${BOLD}$SECRET_NAME_PREFIX/$name${NC}${GREEN}' created successfully!${NC}"
     else
        echo -e "${YELLOW}🔄 AWS Secret exists, updating...${NC}"
        if aws secretsmanager update-secret \
           --secret-id "$SECRET_NAME_PREFIX/$name" \
           --secret-string file://"$file" \
           --region $AWS_REGION >/dev/null 2>&1; then
           echo -e "${GREEN}✅ AWS Secret '${BOLD}$SECRET_NAME_PREFIX/$name${NC}${GREEN}' updated successfully!${NC}"
        else
           echo -e "${RED}❌ Failed to create/update AWS secret${NC}"
           return 1
        fi
     fi
   fi

   # Kubernetes Secret path
   if [ "$USE_K8S_SECRETS" = "true" ]; then
     K8S_SECRET_NAME="${SECRET_NAME_PREFIX}-${name}"
     echo -e "${PURPLE}📥 Creating/updating Kubernetes Secret ${BOLD}${K8S_SECRET_NAME}${NC}...${NC}"
     kubectl --kubeconfig "$KUBECONFIG_FILE" -n default create secret generic "$K8S_SECRET_NAME" \
       --from-file=secret.json="$file" --dry-run=client -o yaml | \
       kubectl --kubeconfig "$KUBECONFIG_FILE" apply -f - >/dev/null
     echo -e "${GREEN}✅ Kubernetes Secret ${BOLD}${K8S_SECRET_NAME}${NC}${GREEN} applied to cluster${NC}"
   fi

   # Cleanup the passed temp file
   if [ -n "$file" ] && [ -f "$file" ]; then
     rm -f "$file"
   fi

   # Show AWS ARN only if AWS path used
   if [ "$USE_AWS_SECRETS" = "true" ]; then
     echo -e "${CYAN}🔐 Secret ARN:${NC} $(aws secretsmanager describe-secret --secret-id "$SECRET_NAME_PREFIX/$name" --region $AWS_REGION --query 'ARN' --output text)"
   fi
}

echo -e "\n${YELLOW}📋 Processing files...${NC}"
TEMP_SECRET_FILE=$(mktemp)

# Start building JSON for Github App secrets
echo "{" > "$TEMP_SECRET_FILE"

first=true
file_count=0
for file in "$PRIVATE_DIR"/*.yaml; do
    if [ -f "$file" ]; then
        filename=$(basename "$file" .yaml)
        echo -e "${CYAN}  📄 Adding:${NC} ${filename}"
        
        # Add comma if not first entry
        if [ "$first" = false ]; then
            echo "," >> "$TEMP_SECRET_FILE"
        fi
        first=false
        
        # Add key-value pair with properly escaped content
        echo -n "  \"$filename\": " >> "$TEMP_SECRET_FILE"
        yq -o=json eval '.' "$file" >> "$TEMP_SECRET_FILE"
        file_count=$((file_count + 1))
    fi
done

if [ $file_count -eq 0 ]; then
    echo -e "${RED}❌ No files found in $PRIVATE_DIR${NC}"
    rm "$TEMP_SECRET_FILE"
    exit 1
fi

echo "" >> "$TEMP_SECRET_FILE"
echo "}" >> "$TEMP_SECRET_FILE"

create_update_secret "github-app" "$TEMP_SECRET_FILE"

# Build JSON for Config secret
TEMP_SECRET_FILE=$(mktemp)
yq -o=json eval '.' "$CONFIG_FILE" > "$TEMP_SECRET_FILE"
create_update_secret "config" "$TEMP_SECRET_FILE"

# Cleanup temp kubeconfig if we created one in /tmp
if [ -n "$KUBECONFIG_FILE" ] && [[ "$KUBECONFIG_FILE" == /tmp/* ]]; then
  rm -f "$KUBECONFIG_FILE" || true
fi

echo -e "\n${BOLD}${GREEN}🎉 Process completed successfully! 🎉${NC}"

