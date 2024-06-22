#!/bin/bash

echo "Provisioning resources..."
npm install hexo-cli -g
git submodule update --init --recursive
git config core.hooksPath hooks
chmod +x hooks/*