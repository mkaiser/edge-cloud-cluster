#!/bin/bash

printf 'username: %s\n' "$(kubectl get secret -n ryaxns ryax-admin-credentials -o jsonpath='{.data.username}' | base64 -d)"
printf 'password: %s\n' "$(kubectl get secret -n ryaxns ryax-admin-credentials -o jsonpath='{.data.password}' | base64 -d)"