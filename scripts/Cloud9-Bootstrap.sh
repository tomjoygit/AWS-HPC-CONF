#!/bin/bash

if [[ -f /home/ec2-user/environment/bootstrap.log ]]; then
    exit 1
fi

set -x
exec >/home/ec2-user/environment/bootstrap.log; exec 2>&1

sudo yum -y -q install jq
sudo chown -R ec2-user:ec2-user /home/ec2-user/
#source cluster profile and move to the home dir
cd /home/ec2-user/environment
. cluster_env

#install Lustre client
sudo amazon-linux-extras install -y lustre2.10 > /dev/null 2>&1

python3 -m pip install "aws-parallelcluster" --upgrade --user --quiet
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.38.0/install.sh | bash
chmod ug+x ~/.nvm/nvm.sh
source ~/.nvm/nvm.sh > /dev/null 2>&1
nvm install --lts=Gallium > /dev/null 2>&1
node --version

if [[ $FSX_ID == "AUTO" ]];then
FSX=$(cat <<EOF
  - MountDir: /fsx
    Name: new
    StorageType: FsxLustre
    FsxLustreSettings:
      StorageCapacity: 1200
      DeploymentType: SCRATCH_2
      ImportedFileChunkSize: 1024
      DataCompressionType: LZ4
      ExportPath: s3://${S3_BUCKET}
      ImportPath: s3://${S3_BUCKET}
      AutoImportPolicy: NEW_CHANGED
EOF
)
else
FSX=$(cat <<EOF
  - MountDir: /fsx
    Name: existing
    StorageType: FsxLustre
    FsxLustreSettings:
      FileSystemId: ${FSX_ID}
EOF
)
fi
export FSX

#/usr/bin/envsubst < "AWS-HPC/parallelcluster/config.${AWS_REGION_NAME}.sample.yaml" > config.${AWS_REGION_NAME}.yaml
/usr/bin/envsubst '${SLURM_DB_ENDPOINT}' < "AWS-HPC/enginframe/mysql/efdb.config" > efdb.config
/usr/bin/envsubst '${SLURM_DB_ENDPOINT}' < "AWS-HPC/enginframe/efinstall.config" > efinstall.config
/usr/bin/envsubst '${S3_BUCKET}' < "AWS-HPC/enginframe/fm.browse.ui" > fm.browse.ui
/usr/bin/envsubst '${S3_BUCKET},${FSX},${AWS_REGION_NAME},${PRIVATE_SUBNET_ID},${ADDITIONAL_SG},${DB_SG},${KEY_PAIR},${SLURM_DB_ENDPOINT},${SECRET_ARN}' < "AWS-HPC/parallelcluster/config.eu-west-1.sample.yaml" > config.${AWS_REGION_NAME}.yaml

aws s3 cp --quiet efinstall.config "s3://${S3_BUCKET}/AWS-HPC/enginframe/efinstall.config" --region "${AWS_REGION_NAME}"
aws s3 cp --quiet fm.browse.ui "s3://${S3_BUCKET}/AWS-HPC/enginframe/fm.browse.ui" --region "${AWS_REGION_NAME}"
aws s3 cp --quiet efdb.config "s3://${S3_BUCKET}/AWS-HPC/enginframe/mysql/efdb.config" --region "${AWS_REGION_NAME}"
aws s3 cp --quiet /usr/bin/mysql "s3://${S3_BUCKET}/AWS-HPC/enginframe/mysql/mysql" --region "${AWS_REGION_NAME}"
aws s3 cp --quiet config.${AWS_REGION_NAME}.yaml "s3://${S3_BUCKET}/AWS-HPC/parallelcluster/" --region "${AWS_REGION_NAME}"
rm -f fm.browse.ui efinstall.config

#Create the key pair (remove the existing one if it has the same name)
# FIX this: create the key on the CF and store on SecretManager
aws ec2 create-key-pair --key-name ${KEY_PAIR} --query KeyMaterial --output text > /home/ec2-user/.ssh/id_rsa
if [ $? -ne 0 ]; then
    aws ec2 delete-key-pair --key-name ${KEY_PAIR}
    aws ec2 create-key-pair --key-name ${KEY_PAIR} --query KeyMaterial --output text > /home/ec2-user/.ssh/id_rsa
fi
sudo chmod 400 /home/ec2-user/.ssh/id_rsa

#Create the cluster and wait
/home/ec2-user/.local/bin/pcluster create-cluster --cluster-name "tme-${CLUSTER_NAME}" --cluster-configuration config.${AWS_REGION_NAME}.yaml --region ${AWS_REGION_NAME} --rollback-on-failure false --wait

HEADNODE_PRIVATE_IP=$(/home/ec2-user/.local/bin/pcluster describe-cluster --cluster-name "tme-${CLUSTER_NAME}" --region ${AWS_REGION_NAME}  | jq -r '.headNode.privateIpAddress')
echo "export HEADNODE_PRIVATE_IP='${HEADNODE_PRIVATE_IP}'" >> cluster_env

# Modify the Message Of The Day
sudo rm -f /etc/update-motd.d/*
#sudo aws s3 cp --quiet "s3://${S3_BUCKET}/AWS-HPC/scripts/motd"  /etc/update-motd.d/10-HPC --region "${AWS_REGION_NAME}" || exit 1
#sudo curl -o- https://github.com/tomjoygit/AWS-HPC/blob/main/scripts/motd > /etc/update-motd.d/10-HPC || exit 1
#sudo chmod +x /etc/update-motd.d/10-HPC
#echo 'run-parts /etc/update-motd.d' >> /home/ec2-user/.bash_profile

#attach the ParallelCluster SG to the Cloud9 instance (for FSx or NFS)
INSTANCE_ID=$(curl http://169.254.169.254/latest/meta-data/instance-id)
SG_CLOUD9=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --query Reservations[*].Instances[*].SecurityGroups[*].GroupId  --region ${AWS_REGION_NAME} --output text)
SG_HEADNODE=$(aws cloudformation describe-stack-resources --stack-name "tme-${CLUSTER_NAME}" --logical-resource-id ComputeSecurityGroup --query "StackResources[*].PhysicalResourceId"  --region ${AWS_REGION_NAME} --output text)
aws ec2 modify-instance-attribute --instance-id $INSTANCE_ID --groups $SG_CLOUD9 $SG_HEADNODE --region ${AWS_REGION_NAME}

#increase the maximum number of files that can be handled by file watcher,
sudo bash -c 'echo "fs.inotify.max_user_watches=524288" >> /etc/sysctl.conf' && sudo sysctl -p

if [[ $FSX_ID == "AUTO" ]];then
  #FSX_ID=$(aws cloudformation describe-stack-resources --stack-name "tme-${CLUSTER_NAME}" --logical-resource-id FSX0 --query "StackResources[*].PhysicalResourceId" --region ${AWS_REGION_NAME} --output text)
   FSX_ID=$(aws cloudformation describe-stack-resources --stack-name "tme-${CLUSTER_NAME}" --query "StackResources[? contains(ResourceType,'AWS::FSx::FileSystem')].PhysicalResourceId" --region ${AWS_REGION_NAME} --output text)
fi

FSX_DNS_NAME=$(aws fsx describe-file-systems --file-system-ids $FSX_ID --query "FileSystems[*].DNSName" --region ${AWS_REGION_NAME} --output text)
FSX_MOUNT_NAME=$(aws fsx describe-file-systems --file-system-ids $FSX_ID  --query "FileSystems[*].LustreConfiguration.MountName" --region ${AWS_REGION_NAME} --output text)

#mount the same FSx created for the HPC Cluster
mkdir fsx
sudo mount -t lustre -o noatime,flock $FSX_DNS_NAME@tcp:/$FSX_MOUNT_NAME fsx
sudo bash -c "echo \"$FSX_DNS_NAME@tcp:/$FSX_MOUNT_NAME /home/ec2-user/environment/fsx lustre defaults,noatime,flock,_netdev 0 0\" >> /etc/fstab"
sudo chmod 755 fsx
sudo chown ec2-user:ec2-user fsx

# send SUCCESFUL to the wait handle
curl -X PUT -H 'Content-Type:' \
    --data-binary "{\"Status\" : \"SUCCESS\",\"Reason\" : \"Configuration Complete\",\"UniqueId\" : \"$HEADNODE_PRIVATE_IP\",\"Data\" : \"$HEADNODE_PRIVATE_IP\"}" \
    "${WAIT_HANDLE}"
