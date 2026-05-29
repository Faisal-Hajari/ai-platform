sudo apt install -y openssh-server
sudo systemctl enable --now ssh
sudo systemctl status ssh