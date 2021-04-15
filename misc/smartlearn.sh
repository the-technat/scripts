#!/bin/bash

sudo ip a del 192.168.210.1/24 dev vmnet1
sudo ip a add 192.168.210.254/24 dev vmnet1

