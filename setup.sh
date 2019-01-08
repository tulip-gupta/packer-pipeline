#!/bin/bash
set -e -o pipefail

# required settings
NODE_NAME="$(curl --silent --show-error --retry 3 http://169.254.169.254/latest/meta-data/instance-id)" # this uses the EC2 instance ID as the node name
CHEF_SERVER_NAME="test-chef" # The name of your Chef Server
CHEF_SERVER_ENDPOINT="test-chef-s7d1jdzzygmgatai.us-east-2.opsworks-cm.io" # The FQDN of your Chef Server
REGION="us-east-2" # Region of your Chef Server (Choose one of our supported regions - us-east-1, us-east-2, us-west-1, us-west-2, eu-central-1, eu-west-1, ap-northeast-1, ap-southeast-1, ap-southeast-2)

# optional settings
CHEF_ORGANIZATION="default" # AWS OpsWorks for Chef Server always creates the organization "default"
NODE_ENVIRONMENT="development" # E.g. development, staging, onebox, ...
CHEF_CLIENT_VERSION="13.8.5" # latest if empty

# extra optional settings
AWS_CLI_EXTRA_OPTS=()
JSON_ATTRIBUTES=''
CFN_SIGNAL=""

ROOT_CA_URL="https://opsworks-cm-${REGION}-prod-default-assets.s3.amazonaws.com/misc/opsworks-cm-ca-2016-root.pem"
RUN_LIST="recipe[chef-client]" # Use "role[opsworks-example-role]" when following the starter kit example or specify recipes like recipe[chef-client],recipe[apache2] etc.

# ---------------------------

AWS_CLI_TMP_FOLDER=$(mktemp --directory "/tmp/awscli_XXXX")
CHEF_CA_PATH="/etc/chef/opsworks-cm-ca-2016-root.pem"

prepare_os_packages() {
  local OS=`uname -a`
  if [[ ${OS} = *"Ubuntu"* ]]; then
    apt update && DEBIAN_FRONTEND=noninteractive apt -y upgrade
    apt -y install unzip python python-pip
    # see: https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/cfn-helper-scripts-reference.html
    pip install https://s3.amazonaws.com/cloudformation-examples/aws-cfn-bootstrap-latest.tar.gz
    ln -s /root/aws-cfn-bootstrap-latest/init/ubuntu/cfn-hup /etc/init.d/cfn-hup
    mkdir -p /opt/aws
    ln -s /usr/local/bin /opt/aws/bin
  fi
}

install_aws_cli() {
  # see: http://docs.aws.amazon.com/cli/latest/userguide/installing.html#install-bundle-other-os
  pushd "${AWS_CLI_TMP_FOLDER}"
  curl --silent --show-error --retry 3 --location --output "awscli-bundle.zip" "https://s3.amazonaws.com/aws-cli/awscli-bundle.zip"
  unzip "awscli-bundle.zip"
  ./awscli-bundle/install -i "${PWD}"
}

aws_cli() {
  "${AWS_CLI_TMP_FOLDER}/bin/aws" opsworks-cm \
    --region "${REGION}" ${AWS_CLI_EXTRA_OPTS[@]:-} --output text "$@" --server-name "${CHEF_SERVER_NAME}"
}



write_chef_config() {
  (
    echo "chef_server_url   'https://${CHEF_SERVER_ENDPOINT}/organizations/${CHEF_ORGANIZATION}'"
    echo "node_name         '${NODE_NAME}'"
    echo "ssl_ca_file       '${CHEF_CA_PATH}'"
  ) >> /etc/chef/client.rb
}

install_chef_client() {
  # see: https://docs.chef.io/install_omnibus.html
  curl --silent --show-error --retry 3 --location https://omnitruck.chef.io/install.sh | bash -s -- -v "${CHEF_CLIENT_VERSION}"
}

install_trusted_certs() {
  curl --silent --show-error --retry 3 --location --output "${CHEF_CA_PATH}" ${ROOT_CA_URL}
}

wait_node_associated() {
  aws_cli wait node-associated --node-association-status-token "$1"
}

# order of execution of functions
prepare_os_packages
install_aws_cli
install_chef_client
write_chef_config
install_trusted_certs
wait_node_associated "${node_association_status_token}"

if [ ! -z ${RUN_LIST} ]; then
  CHEF_CLIENT_OPTS=(-r ${RUN_LIST})
fi
if [ ! -z ${JSON_ATTRIBUTES} ]; then
  echo ${JSON_ATTRIBUTES} > /tmp/chef-attributes.json
  CHEF_CLIENT_OPTS+=(-j /tmp/chef-attributes.json)
fi
if [ ! -z ${NODE_ENVIRONMENT} ]; then
  CHEF_CLIENT_OPTS+=(-E ${NODE_ENVIRONMENT});
fi
# initial chef-client run to register nod
if [ ! -z ${CHEF_CLIENT_OPTS} ]; then
  chef-client ${CHEF_CLIENT_OPTS[@]}
fi

touch /tmp/userdata.done
eval ${CFN_SIGNAL}

