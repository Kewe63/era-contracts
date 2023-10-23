#!/bin/bash

# install rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

rustup toolchain install nightly

# install era-test-node
cargo +nightly install --git https://github.com/matter-labs/era-test-node.git --locked --branch boojum-integration-vm-1.4.1

yarn
yarn build
yarn preprocess && yarn compile-yul
era_test_node run > /dev/null 2>&1 & export TEST_NODE_PID=$!
yarn test
kill $TEST_NODE_PID