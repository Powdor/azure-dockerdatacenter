#!/bin/bash

# We need four params: (1) PASSWORD (2) MASTERFQDN (3) REPLICA_ID (4) MASTERPRIVATEIP (5) DTRNODE (6) SLEEP

echo $(date) " - Starting Script"

USER=admin
PASSWORD=$1
MASTERFQDN=$2
UCP_URL=https://$4
UCP_NODE=$(hostname)
REPLICA_ID=$3
MASTERPRIVATEIP=$4
DTRNODE=$5
SLEEP= $6

if [ ! -z "$6" ]; then
omsworkspaceid=$6
omsworkspacekey=$7
omslnxagentver=$8
echo  "omsworkspaceid is" $omsworkspaceid
else
echo "All are respectively " $1 $2 $3 $4 $5
fi
DOCKERDET=$9
DOCKERVER=$( echo "$9" |cut -d\: -f1 )
DOCKERCOMPVER=$( echo "$9" |cut -d\: -f2 )
DOCKERMCVER=$( echo "$9" |cut -d\: -f3 )
TRUSTYREPO=$( echo "$9" |cut -d\: -f4 )
DOCKERDCVER=$( echo "$9" |cut -d\: -f5 )

installomsagent()
{
#wget https://github.com/Microsoft/OMS-Agent-for-Linux/releases/download/OMSAgent_Ignite2016_v$omslnxagentver/omsagent-${omslnxagentver}.universal.x64.sh
wget https://github.com/Microsoft/OMS-Agent-for-Linux/releases/download/OMSAgent-201610-v$omslnxagentver/omsagent-${omslnxagentver}.universal.x64.sh
chmod +x ./omsagent-${omslnxagentver}.universal.x64.sh
md5sum ./omsagent-${omslnxagentver}.universal.x64.sh
sudo sh ./omsagent-${omslnxagentver}.universal.x64.sh --upgrade -w $omsworkspaceid -s $omsworkspacekey
}

instrumentfluentd_docker()
{
cd /etc/systemd/system/multi-user.target.wants/ && sed -i.bak -e '12d' docker.service
cd /etc/systemd/system/multi-user.target.wants/ && sed -i '12iEnvironment="DOCKER_OPTS=--log-driver=fluentd --log-opt fluentd-address=localhost:25225"' docker.service
cd /etc/systemd/system/multi-user.target.wants/ && sed -i '13iExecStart=/usr/bin/dockerd -H fd:// $DOCKER_OPTS' docker.service
service docker restart
}
install_docker_tools()
{

# System Update and docker version update
DEBIAN_FRONTEND=noninteractive apt-get -y update
apt-get install -y apt-transport-https ca-certificates
#apt-key adv --keyserver hkp://p80.pool.sks-keyservers.net:80 --recv-keys 58118E89F3A912897C070ADBF76221572C52609D
#echo 'deb https://apt.dockerproject.org/repo ubuntu-trusty main' >> /etc/apt/sources.list.d/docker.list
#echo 'deb https://packages.docker.com/1.12/apt/repo ubuntu-trusty testing' >> /etc/apt/sources.list.d/docker.list
echo "deb https://packages.docker.com/${DOCKERVER}/apt/repo ubuntu-trusty ${TRUSTYREPO}" >> /etc/apt/sources.list.d/docker.list
apt-cache policy docker-engine
DEBIAN_FRONTEND=noninteractive apt-get -y update
DEBIAN_FRONTEND=noninteractive apt-get -y upgrade
#curl -L https://github.com/docker/compose/releases/download/1.9.0-rc4/docker-compose-`uname -s`-`uname -m` > /usr/local/bin/docker-compose
#curl -L https://github.com/docker/machine/releases/download/v0.8.2/docker-machine-`uname -s`-`uname -m` >/usr/local/bin/docker-machine
curl -L https://github.com/docker/compose/releases/download/$DOCKERCOMPVER/docker-compose-`uname -s`-`uname -m` > /usr/local/bin/docker-compose
curl -L https://github.com/docker/machine/releases/download/v$DOCKERMCVER/docker-machine-`uname -s`-`uname -m` >/usr/local/bin/docker-machine
chmod +x /usr/local/bin/docker-machine
chmod +x /usr/local/bin/docker-compose
export PATH=$PATH:/usr/local/bin/
groupadd docker
usermod -aG docker ucpadmin
service docker restart
}
install_docker_tools;
if [ ! -z "$6" ]; then
sleep 45;
instrumentfluentd_docker;
sleep 30;
installomsagent;
fi

# Implement delay timer to stagger joining of Agent Nodes to cluster
echo $(date) " - Loading docker install Tar"
#cd /opt/ucp && wget https://s3.amazonaws.com/packages.docker.com/caas/ucp-2.0.0-beta3_dtr-2.1.0-beta3.tar.gz
#cd /opt/ucp && wget https://packages.docker.com/caas/ucp-2.0.0-beta4_dtr-2.1.0-beta4.tar.gz
cd /opt/ucp && wget https://packages.docker.com/caas/$DOCKERDCVER.tar.gz
#docker load < ucp-2.0.0-beta4_dtr-2.1.0-beta4.tar.gz
docker load < $DOCKERDCVER.tar.gz

# Start installation of UCP with master Controller

echo $(date) " - Loading complete.  Starting UCP Install"

installbundle ()
{

echo $(date) "Sleeping for $SLEEP"
sleep $SLEEP
echo $(date) " - Staring Swarm Join as worker UCP Controller"
apt-get -y update && apt-get install -y curl jq
# Create an environment variable with the user security token
AUTHTOKEN=$(curl -sk -d '{"username":"admin","password":"'"$PASSWORD"'"}' https://$MASTERPRIVATEIP/auth/login | jq -r .auth_token)
echo "$AUTHTOKEN"
# Download the client certificate bundle
curl -k -H "Authorization: Bearer ${AUTHTOKEN}" https://$MASTERPRIVATEIP/api/clientbundle -o bundle.zip
unzip -o bundle.zip && chmod +x env.sh && source env.sh
}
joinucp() {
installbundle;
#docker swarm join-token worker|sed '1d'|sed '1d'|sed '$ d'>swarmjoin.sh
docker swarm join-token worker|sed '1d'|sed '1d'|sed '$ d'> /usr/local/bin/docker-workerswarmjoin
unset DOCKER_TLS_VERIFY
unset DOCKER_CERT_PATH
unset DOCKER_HOST
#chmod 755 swarmjoin.sh
chmod +x /usr/local/bin/docker-workerswarmjoin
export PATH=$PATH:/usr/local/bin/
docker-workerswarmjoin
#source swarmjoin.sh
}
installdtr() {
installbundle;
## Insecure TLS as self signed will fail -- Failed to get bootstrap client: Failed to get UCP CA: Get https://blablah/ca: x509: certificate signed by unknown authority
docker run --rm -i \
  docker/dtr:2.1.0-beta4 install \
  --ucp-node $UCP_NODE \
  --ucp-insecure-tls \
  --dtr-external-url $DTR_PUBLIC_URL  \
  --ucp-url https://$MASTERFQDN \
  --ucp-username admin --ucp-password $PASSWORD
  }
sleep 45;
joinucp;
#echo $(date) "Sleeping for 200"
#sleep 200;
# Install DTR
#installdtr;

if [ $? -eq 0 ]
then
 echo $(date) " - UCP installed and started on the agent node to be used for DTR replica"
else
 echo $(date) " -- UCP installation failed on DTR node"
fi
