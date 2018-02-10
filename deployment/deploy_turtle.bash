#!/bin/bash
echo "This assumes that you are doing a green-field install.  If you're not, please exit in the next 15 seconds."
sleep 15
echo "Continuing install, this will prompt you for your password if you're not already running as root and you didn't enable passwordless sudo.  Please do not run me as root!"
if [[ `whoami` == "root" ]]; then
    echo "You ran me as root! Do not run me as root!"
    exit 1
fi
sudo DEBIAN_FRONTEND=interactive
echo "Before we get started, we need a bit of info from you..."
echo ""
read -p "Mailgun Key (Enter to skip): " mailgunKey
read -p "Mailgun URL (Enter to skip): " mailgunURL
read -p "Address Email comes From: " emailFrom
read -p "Administrator Password: " adminPass
clear
echo "We need the following information to set up the daemon and wallet..."
echo ""
read -p "Pool Wallet Name: " poolWalletName
read -p "Pool Wallet Password: " poolWalletPassword
read -p "Pool Wallet RPC Password: " poolWalletRPCPassword
read -p "Fee Wallet Address: " feeAddress
clear
echo "Thank you. Continuing with Install."
ROOT_SQL_PASS=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)
CURUSER=$(whoami)
echo "Etc/UTC" | sudo tee -a /etc/timezone
sudo rm -rf /etc/localtime
sudo ln -s /usr/share/zoneinfo/Zulu /etc/localtime
sudo dpkg-reconfigure -f noninteractive tzdata
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get -y upgrade
sudo debconf-set-selections <<< "mysql-server mysql-server/root_password password $ROOT_SQL_PASS"
sudo debconf-set-selections <<< "mysql-server mysql-server/root_password_again password $ROOT_SQL_PASS"
echo -e "[client]\nuser=root\npassword=$ROOT_SQL_PASS" | sudo tee /root/.my.cnf
sudo DEBIAN_FRONTEND=noninteractive apt-get -y install git python-virtualenv python3-virtualenv curl ntp build-essential screen cmake pkg-config libboost-all-dev libevent-dev libunbound-dev libminiupnpc-dev libunwind8-dev liblzma-dev libldns-dev libexpat1-dev libgtest-dev mysql-server lmdb-utils libzmq3-dev
cd /usr/src/gtest
sudo cmake .
sudo make
sudo mv libg* /usr/lib/
cd ~
sudo systemctl enable ntp
cd /usr/local/src
su -u root -H curl -sL "https://raw.githubusercontent.com/turtlecoin/turtlecoin/master/multi_installer.sh" | bash
echo "Generating new Pool Wallet..."
cd ./turtlecoin/build/src
./walletd --container-file=$poolWalletName --container-password=$poolWalletPassword --generate-container
poolWallet=$(fgrep "New wallet is generated. Address:" walletd.log | sed 's/.*\ //')
sudo cp ~/nodejs-pool/deployment/turtle.service /lib/systemd/system/
sudo useradd -m turtledaemon -d /home/turtledaemon
sudo -u turtledaemon mkdir /home/turtledaemon/.TurtleCoin
sudo systemctl daemon-reload
sudo systemctl enable turtle
sudo systemctl start turtle
curl -o- https://raw.githubusercontent.com/creationix/nvm/v0.33.0/install.sh | bash
source ~/.nvm/nvm.sh
nvm install v6.9.2
cd ~/nodejs-pool
npm install
npm install -g pm2
openssl req -subj "/C=IT/ST=Pool/L=Daemon/O=Mining Pool/CN=mining.pool" -newkey rsa:2048 -nodes -keyout cert.key -x509 -out cert.pem -days 36500
mkdir ~/pool_db/
sed -r "s/(\"db_storage_path\": ).*/\1\"\/home\/$CURUSER\/pool_db\/\",/" config_example.json > config.json
cd ~
git clone https://github.com/TwistedStudiosLLC/turtlepoolui.git
cd turtlepoolui
npm install
./node_modules/bower/bin/bower update
./node_modules/gulp/bin/gulp.js build
cd build
sudo ln -s `pwd` /var/www
CADDY_DOWNLOAD_DIR=$(mktemp -d)
cd $CADDY_DOWNLOAD_DIR
curl -sL "https://snipanet.com/caddy.tar.gz" | tar -xz caddy init/linux-systemd/caddy.service
sudo mv caddy /usr/local/bin
sudo chown root:root /usr/local/bin/caddy
sudo chmod 755 /usr/local/bin/caddy
sudo setcap 'cap_net_bind_service=+ep' /usr/local/bin/caddy
sudo groupadd -g 33 www-data
sudo useradd -g www-data --no-user-group --home-dir /var/www --no-create-home --shell /usr/sbin/nologin --system --uid 33 www-data
sudo mkdir /etc/caddy
sudo chown -R root:www-data /etc/caddy
sudo mkdir /etc/ssl/caddy
sudo chown -R www-data:root /etc/ssl/caddy
sudo chmod 0770 /etc/ssl/caddy
sudo cp ~/nodejs-pool/deployment/caddyfile /etc/caddy/Caddyfile
sudo chown www-data:www-data /etc/caddy/Caddyfile
sudo chmod 444 /etc/caddy/Caddyfile
sudo sh -c "sed 's/ProtectHome=true/ProtectHome=false/' init/linux-systemd/caddy.service > /etc/systemd/system/caddy.service"
sudo chown root:root /etc/systemd/system/caddy.service
sudo chmod 644 /etc/systemd/system/caddy.service
sudo systemctl daemon-reload
sudo systemctl enable caddy.service
sudo systemctl start caddy.service
rm -rf $CADDY_DOWNLOAD_DIR
cd ~
sudo env PATH=$PATH:`pwd`/.nvm/versions/node/v6.9.2/bin `pwd`/.nvm/versions/node/v6.9.2/lib/node_modules/pm2/bin/pm2 startup systemd -u $CURUSER --hp `pwd`
cd ~/nodejs-pool
sudo chown -R $CURUSER. ~/.pm2
echo "Installing pm2-logrotate in the background!"
pm2 install pm2-logrotate &
echo "Setting up SQL DB"
mysql -u root --password=$ROOT_SQL_PASS < deployment/base.sql
mysql -u root --password=$ROOT_SQL_PASS pool -e "INSERT INTO pool.config (module, item, item_value, item_type, Item_desc) VALUES ('api', 'authKey', '`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1`', 'string', 'Auth key sent with all Websocket frames for validation.')"
mysql -u root --password=$ROOT_SQL_PASS pool -e "INSERT INTO pool.config (module, item, item_value, item_type, Item_desc) VALUES ('api', 'secKey', '`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1`', 'string', 'HMAC key for Passwords.  JWT Secret Key.  Changing this will invalidate all current logins.')"
mysql -u root --password=$ROOT_SQL_PASS pool -e "UPDATE pool.config SET item_value = '$poolWallet' WHERE module = 'pool' and item = 'address'"
mysql -u root --password=$ROOT_SQL_PASS pool -e "UPDATE pool.config SET item_value = '$feeAddress' WHERE module = 'payout' and item = 'feeAddress'"
mysql -u root --password=$ROOT_SQL_PASS pool -e "UPDATE pool.config SET item_value = '$mailgunKey' WHERE module = 'payout' and item = 'mailgunKey'"
mysql -u root --password=$ROOT_SQL_PASS pool -e "UPDATE pool.config SET item_value = '$mailgunURL' WHERE module = 'payout' and item = 'mailgunURL'"
mysql -u root --password=$ROOT_SQL_PASS pool -e "UPDATE pool.config SET item_value = '$emailFrom' WHERE module = 'payout' and item = 'emailFrom'"
mysql -u root --password=$ROOT_SQL_PASS pool -e "UPDATE pool.config SET item_value = 'http://127.0.0.1:8000/leafApi' WHERE module = 'payout' and item = 'shareHost'"
mysql -u root --password=$ROOT_SQL_PASS pool -e "UPDATE pool.users SET email='$adminPass' WHERE username='Administrator'"
pm2 start init.js --name=api --log-date-format="YYYY-MM-DD HH:mm Z" -- --module=api
bash ~/nodejs-pool/deployment/install_lmdb_tools.sh
cd ~/nodejs-pool/sql_sync/
env PATH=$PATH:`pwd`/.nvm/versions/node/v6.9.2/bin node sql_sync.js
echo "DB Setup Complete. Starting all PM2 Services."
cd ~/nodejs-pool/
pm2 start /usr/local/src/turtlecoin/build/src/walletd -- --container-file=$poolWalletName --container-password=$poolWalletPassword --rpc-password=$poolWalletRPCPassword --server-root=/usr/local/src/turtlecoin/build/src --local --daemon
pm2 start init.js --name=blockManager --log-date-format="YYYY-MM-DD HH:mm Z"  -- --module=blockManager
pm2 start init.js --name=worker --log-date-format="YYYY-MM-DD HH:mm Z" -- --module=worker
pm2 start init.js --name=payments --log-date-format="YYYY-MM-DD HH:mm Z" -- --module=payments
pm2 start init.js --name=remoteShare --log-date-format="YYYY-MM-DD HH:mm Z" -- --module=remoteShare
pm2 start init.js --name=longRunner --log-date-format="YYYY-MM-DD HH:mm Z" -- --module=longRunner
pm2 start init.js --name=pool --log-date-format="YYYY-MM-DD HH:mm Z" -- --module=pool
pm2 restart api
echo "You're all setup!"
