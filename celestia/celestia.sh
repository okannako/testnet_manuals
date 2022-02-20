#!/usr/bin/env bash
. ~/.bashrc

if [ $# -eq 0 ]
  then
	CELESTIA_MODE="validator"
else
	CELESTIA_MODE="validator,$1"
fi
echo 'export CELESTIA_MODE='$CELESTIA_MODE >> $HOME/.bash_profile
. ~/.bash_profile

if [ ! $CELESTIA_NODENAME ]; then
	read -p "Enter node name: " CELESTIA_NODENAME
	echo 'export CELESTIA_NODENAME='$CELESTIA_NODENAME >> $HOME/.bash_profile
	. ~/.bash_profile
fi

echo 'export CELESTIA_WALLET=wallet' >> $HOME/.bash_profile
echo 'export CELESTIA_CHAIN=devnet-2' >> $HOME/.bash_profile
CELESTIA_NODE_VERSION=$(curl -s "https://raw.githubusercontent.com/kj89/testnet_manuals/main/celestia/latest_node.txt")
CELESTIA_APP_VERSION=$(curl -s "https://raw.githubusercontent.com/kj89/testnet_manuals/main/celestia/latest_app.txt")
echo 'export CELESTIA_NODE_VERSION='$CELESTIA_NODE_VERSION >> $HOME/.bash_profile
echo 'export CELESTIA_APP_VERSION='$CELESTIA_APP_VERSION >> $HOME/.bash_profile
source $HOME/.bash_profile


echo '==================================='
echo 'Your celestia mode: ' $CELESTIA_MODE
echo 'Your node name: ' $CELESTIA_NODENAME
echo 'Your walet name: ' $CELESTIA_WALLET
echo 'Your chain name: ' $CELESTIA_CHAIN
echo 'Your node version: ' $CELESTIA_NODE_VERSION
echo 'Your app version: ' $CELESTIA_APP_VERSION
echo '==================================='

sleep 5
# update packages
echo "nameserver 8.8.8.8" | sudo tee /etc/resolv.conf > /dev/null
export DEBIAN_FRONTEND=noninteractive
apt-get update && 
    apt-get -o Dpkg::Options::="--force-confold" upgrade -q -y --force-yes &&
    apt-get -o Dpkg::Options::="--force-confold" dist-upgrade -q -y --force-yes
sleep 3
sudo apt-get install build-essential -y && sudo apt-get install jq -y
sleep 1

sudo rm -rf /usr/local/go
curl https://dl.google.com/go/go1.17.2.linux-amd64.tar.gz | sudo tar -C/usr/local -zxvf -

cat <<'EOF' >> $HOME/.bash_profile
export GOROOT=/usr/local/go
export GOPATH=$HOME/go
export GO111MODULE=on
export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin
EOF

. $HOME/.bash_profile

cp /usr/local/go/bin/go /usr/bin

go version

# install app
rm -rf celestia-app
cd $HOME
git clone https://github.com/celestiaorg/celestia-app.git
cd celestia-app
git checkout $CELESTIA_APP_VERSION
make install

# install celestia scripts
cd $HOME
git clone https://github.com/celestiaorg/networks.git

###### INITIALIZE AND CONFIGURE CELESTIA VALIDATOR #######
# do init
celestia-appd init $CELESTIA_NODENAME --chain-id $CELESTIA_CHAIN

# get network configs
cp ~/networks/$CELESTIA_CHAIN/genesis.json  ~/.celestia-app/config/

# update seeds
seeds='"74c0c793db07edd9b9ec17b076cea1a02dca511f@46.101.28.34:26656"'
echo $seeds
sed -i.bak -e "s/^seeds *=.*/seeds = $seeds/" $HOME/.celestia-app/config/config.toml

# open rpc
# sed -i 's#"tcp://127.0.0.1:26657"#"tcp://0.0.0.0:26657"#g' $HOME/.celestia-app/config/config.toml

# set proper defaults
sed -i 's/timeout_commit = "5s"/timeout_commit = "15s"/g' $HOME/.celestia-app/config/config.toml
sed -i 's/index_all_keys = false/index_all_keys = true/g' $HOME/.celestia-app/config/config.toml

# config pruning
pruning="custom"
pruning_keep_recent="100"
pruning_keep_every="5000"
pruning_interval="10"

sed -i -e "s/^pruning *=.*/pruning = \"$pruning\"/" $HOME/.celestia-app/config/app.toml
sed -i -e "s/^pruning-keep-recent *=.*/pruning-keep-recent = \"$pruning_keep_recent\"/" $HOME/.celestia-app/config/app.toml
sed -i -e "s/^pruning-keep-every *=.*/pruning-keep-every = \"$pruning_keep_every\"/" $HOME/.celestia-app/config/app.toml
sed -i -e "s/^pruning-interval *=.*/pruning-interval = \"$pruning_interval\"/" $HOME/.celestia-app/config/app.toml

# reset
celestia-appd unsafe-reset-all

# download addrbook
wget -O $HOME/.celestia-app/config/addrbook.json "https://raw.githubusercontent.com/maxzonder/celestia/main/addrbook.json"

# set client config
celestia-appd config chain-id $CELESTIA_CHAIN
celestia-appd config keyring-backend test

# Run as service
sudo tee <<EOF >/dev/null /etc/systemd/system/celestia-appd.service
[Unit]
Description=celestia-appd Cosmos daemon
After=network-online.target

[Service]
User=$USER
ExecStart=$HOME/go/bin/celestia-appd start
Restart=on-failure
RestartSec=3
LimitNOFILE=4096

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl enable celestia-appd
sudo systemctl daemon-reload
sudo systemctl restart celestia-appd

# make a copy of configuration file
cp $HOME/.celestia-app/config/config.toml $HOME/.celestia-app/config/config.toml.bak

if [ $1 = "full" ]
  then
    echo "Setting up local full node"
	sleep 5
	
	# install node
	cd $HOME
	git clone https://github.com/celestiaorg/celestia-node.git
	cd celestia-node/
	git checkout $CELESTIA_NODE_VERSION
	make install

	###### INITIALIZE AND CONFIGURE CELESTIA FULL NODE #######

	# use localhost
	TRUSTED_SERVER="http://localhost:26657"

	# current block hash
	TRUSTED_HASH=$(curl -s $TRUSTED_SERVER/status | jq -r .result.sync_info.latest_block_hash)

	echo '==================================='
	echo 'Your trusted server:' $TRUSTED_SERVER
	echo 'Your trusted hash:' $TRUSTED_HASH
	echo 'Your node version:' $CELESTIA_NODE_VERSION
	echo '==================================='

	# save vars
	echo 'export TRUSTED_SERVER='${TRUSTED_SERVER} >> $HOME/.bash_profile
	echo 'export TRUSTED_HASH='${TRUSTED_HASH} >> $HOME/.bash_profile
	source $HOME/.bash_profile

	# do init
	rm -rf $HOME/.celestia-full
	celestia full init --core.remote $TRUSTED_SERVER --headers.trusted-hash $TRUSTED_HASH

	# config p2p
	sed -i.bak -e 's/PeerExchange = false/PeerExchange = true/g' $HOME/.celestia-full/config.toml

	# Run as service
	sudo tee /etc/systemd/system/celestia-full.service > /dev/null <<EOF
[Unit]
Description=celestia-full node
After=network-online.target
[Service]
User=$USER
ExecStart=$(which celestia) full start
Restart=on-failure
RestartSec=10
LimitNOFILE=4096
[Install]
WantedBy=multi-user.target
EOF

	sudo systemctl enable celestia-full
	sudo systemctl daemon-reload
	sudo systemctl restart celestia-full
fi

echo '==================================='
echo 'Setup is finished!'
echo 'To check logs: journalctl -fu celestia-full -o cat'
echo 'To check validator sync status: curl -s localhost:26657/status | jq .result | jq .sync_info' 
echo '==================================='
