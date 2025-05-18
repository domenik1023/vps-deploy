# Ansible Playbook for VPS Hardening

## Description

This playbook is designed to harden a Virtual Private Server (VPS) by configuring SSH key-only authentication, changing the default SSH port, and applying firewall rules.

## Usage

ansible-playbook main.yml -i inventory --private-key=~/.ssh/domenik1023 -K
