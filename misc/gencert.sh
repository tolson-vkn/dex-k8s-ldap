#!/bin/bash

SSL_DIR=../ssl
mkdir -p $SSL_DIR

cat << EOF > $SSL_DIR/req.cnf
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name

[req_distinguished_name]

[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = *.example.com
DNS.2 = *.kube-auth.svc.cluster.local
EOF

openssl genrsa -out $SSL_DIR/ca-key.pem 2048
openssl req -x509 -new -nodes -key $SSL_DIR/ca-key.pem -days 10 -out $SSL_DIR/ca.pem -subj "/CN=kube-ca"

openssl genrsa -out $SSL_DIR/key.pem 2048
openssl req -new -key $SSL_DIR/key.pem -out $SSL_DIR/csr.pem -subj "/CN=kube-ca" -config $SSL_DIR/req.cnf
openssl x509 -req -in $SSL_DIR/csr.pem -CA $SSL_DIR/ca.pem -CAkey $SSL_DIR/ca-key.pem -CAcreateserial -out $SSL_DIR/cert.pem -days 10 -extensions v3_req -extfile $SSL_DIR/req.cnf
