sudo apt update
sudo apt install -y software-properties-common
sudo add-apt-repository --yes --update ppa:ansible/ansible
sudo apt install -y ansible

# Ansible <= 2.21 can't work with sudo-rs. 
# for systems with sudo-rs you will to change to sudo  
# sudo apt remove sudo-rs && sudo apt install sudo. 

