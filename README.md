# DEX K8S LDAP

This is a repo with an example configuration for Kuberentes authentication with Dex and LDAP.

If you follow the steps defined in here you can setup sandbox infrastructure
to learn how dex works so that you can build a production deployment. This repo
cannot and should not be copy-pasted in to production because it uses; NodePorts,
/etc/host modifications, insecure defaults, and so forth. These will be mentioned
when they should be changed.

This has been tested using a self hosted cluster like `kubeadm`. But additional cloud
provider / baremetal gotchas will be called out.

## Layout

This repo ships with all the components required to deploy as kubernetes manifests
and scripts.

```
# This isn't every file in the repo
├── dex (required)
├── openldap (required - for LDAP SSO, remember you can use other https://github.com/dexidp/dex/tree/master/Documentation/connectors)
├── misc
│   ├── kube-oidc-proxy (optional - if cloud provider or can't change api-server args)
│   ├── teams (optional - default namespaces and roles mapped to oidc groups)
│   └── namespace.yaml (required)
└── phpldapadmin (optional - useful web ui to look at LDAP if you aren't familiar)
```

### /bin

`example-app` is just taken right form [dex](https://github.com/dexidp/dex)

## Safety

This shouldn't scare you away from DEX. These are all security condsiderations I am leaving
out in order to demo/teach how dex works. In a production environment these are easily addressed
and the stack is very secure. I'll try to call out all the high notes of what must be changed
before calling this prod.

#### LDAP

Passwords for LDAP are everywhere: `ldapPa55word`.

LDAP has but doesn't enforce TLS, but you should enforce.

LDAP domain is example.com. Never use a domain you don't own.

PHPLDAPadmin has no TLS either. Probably don't even deploy this to prod..

Of course don't use these users, but if you do, they all have the password `password`

LDAP deploy has no storage backend.

#### TLS

We will create a self-signed cert. You should really use something like [Let's Encrypt](https://letsencrypt.org/docs/).

The K8s way to get certs from Let's Encrypt is with [cert-manager](https://github.com/jetstack/cert-manager)

If you don't want to setup cert-manager and want to do this demo with a Let's Encrypt cert the easiest way
would be to use [certbot's](https://certbot.eff.org/) `certbot certonly --manual --preferred-challenges dns` manual mode.
But remember this cert lacks automation to renew.

If you use a let's encrypt cert you will need the CA for `--oidc-ca-file` (discussed later), you can get that here:
[Let’s Encrypt Authority X3 (IdenTrust cross-signed)](https://letsencrypt.org/certificates/)

### Dex

Dex is not talking to LDAP with TLS.

Dex is viewing LDAP with the admin account. This should be a read only user.

I am using the `example-app --client-secret` default OAuth2 client secret `ZXhhbXBsZS1hcHAtc2VjcmV0`, generate
your own when going to prod.


## Demo / Tutorial

### 0a. Have kube admin rights on a cluster

Create our namespace `kube-auth`

```
$ kubectl apply -f misc/namespace.yaml
```

### 0b. Create self signed cert put it in the cluster

```
$ cd scripts/
$ ./gencert.sh
```

You should see a directory at the repo root like this:

```
$ ls ssl/
ca-key.pem  ca.pem  ca.srl  cert.pem  csr.pem  key.pem  req.cnf
```

You can validate these cert with: `openssl x509 -noout -text -in ssl/cert.pem`

Create the TLS certificate in Kubernetes:

```
$ kubectl create secret tls auth-tls -n kube-auth --cert=ssl/cert.pem --key=ssl/key.pem
```

### 1. Apply base manifests and configuration

#### OpenLDAP

```
$ kubectl apply -f openldap/
```

Once openldap is ready (`kubectl get pods -n kube-auth -l app=openldap`) we can deploy the initial LDAP
config:


```
cd misc/
ldap_config=config-ldap.ldif
openldap_pod=$(kubectl get pods -l app=openldap -n kube-auth -o=jsonpath='{.items[0].metadata.name}')
kubectl cp $ldap_config $openldap_pod:/tmp/$ldap_config
kubectl exec -i -t -n kube-auth $openldap_pod -- ldapadd \
-x \
-D "cn=admin,dc=example,dc=com" \
-H ldap://localhost:389/ \
-f /tmp/$ldap_config \
-w ldapPa55word
kubectl exec -i -t -n kube-auth $openldap_pod rm /tmp/$ldap_config
```

You will see logs like: `adding new entry "cn=xen,ou=Groups,dc=example,dc=com"`, this is good.

You can see from the `deploy.yaml` file that the LDAP store is EmptyDir, so if this pod is restarted, repeat this step.
Or implement storage.

You can validate further with:

```
kubectl exec -i -t -n kube-auth $openldap_pod bash
root@openldap-fc7dd88cb-gxjwm:/# LDAPTLS_REQCERT=never ldapsearch -x -H ldaps://10.103.86.56:636 -b dc=example,dc=com -D "cn=admin,dc=example,dc=com" -w ldapPa55word
```

#### Optional PHPLDAPAdmin

In case you want to view LDAP from a web ui:

```
$ kubectl apply -f phpldapadmin/
```

Go to: http://<NODE-IP>:<NODE-PORT> and enter the Login DN: `cn=admin,dc=example,dc=com` and Password: `ldapPa55word`

#### Dex

Deploy the dex stack:

```
$ kubectl apply -f dex/
```

### 3. Validate Dex and other components

Ideally you see the following:

```
$ kubectl get pod,deploy,svc
NAME                                READY   STATUS    RESTARTS   AGE
pod/dex-5c5958d47-xqc6p             1/1     Running   0          33m
pod/openldap-fc7dd88cb-jsf6j        1/1     Running   0          63m
pod/phpldapadmin-5bfd9bcb87-nfzmw   1/1     Running   0          65m

NAME                           READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/dex            1/1     1            1           44m
deployment.apps/openldap       1/1     1            1           159m
deployment.apps/phpldapadmin   1/1     1            1           65m

NAME                   TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)           AGE
service/dex            NodePort    10.110.63.41   <none>        5556:32000/TCP    45m
service/openldap       ClusterIP   10.103.86.56   <none>        389/TCP,636/TCP   159m
service/phpldapadmin   NodePort    10.96.146.75   <none>        80:30396/TCP      65m
```

We will want to authenticate against dex. This will not get us cluster access yet but
is worth doing before the next steps.

We need to access our NodePort service, and we need to do so with a proper SAN in our
TLS handshake. So if you don't have a DNS record of `dex.example.com` to your K8s node,
set one in your _local_ `/etc/hosts/`

With the host record set run:

```
$ ./bin/example-app --issuer https://dex.example.com:32000 --issuer-root-ca ./ssl/ca.pem
```

Go to http://127.0.0.1:5555 as instructed. In the 3 boxes write `groups` in Extra scopes and
click Login.

> The extra scopes `groups` option allows us to get our LDAP group information, Such as
> user `jdavis` is a member of managers. The `example-app` doesn't do this automatically because
> groups is not technically an offical OIDC field. Though it's widely used in the industry.
> If you/we wrote our own tool to replace `example-app` we could chose to make this default behavior.

Select Log in with LDAP and login as a user.

For example login as `mmiller@example.com` | `password`

You will be returned to http://127.0.0.1:5555 with an ID Token JWT, Access Token JWT, Claims payload,
and refresh token.

We will use these later. For now move to the next step or redo the last steps if it doesn't work.

### 4. Enable OIDC for K8s

#### Self Hosted Way (access to kube-apiserver)

If you're using a dex on a NodePort for this demo then you must also setup a record in your DNS or
set on the K8s node as `/etc/hosts` like we did for your client machine. Otherwise the APIsever
will not be able to find our NodePort service.

> This is another unfortunate symptom of a demo environment and doesn't reflect behavior in production
> where we'd use a LoadBalancer service for dex.
> `1 oidc.go:224] oidc authenticator: initializing plugin: Get https://dex.example.com:32000/.well-known/openid-configuration: dial tcp: lookup dex.example.com on 10.5.1.1:53: no such host`


Copy your ca cert to all hosts running the `kube-apiserver`, and rename it. Your milage may vary on
what your APIserver cert path is. For me it's `/etc/ssl/certs/`.

The kube-apiserver pod-manifest managed in `/etc/kubernetes/manifests/kube-apiserver.yaml`

In the APIserver yaml I see my host cert path /etc/ssl/certs as part of a `hostPath` mount:

```
  volumes:
  - hostPath:
      path: /etc/ssl/certs
      type: DirectoryOrCreate
```

This tells me all I need to do is add my cert to the host path, add my arguments to the APIserver,
restart the APIserver.

```
scp ./ssl/ca.pem root@<NODE-IP>:/etc/ssl/certs/openid-ca.pem
```

```
vim /etc/kubernetes/manifests/kube-apiserver.yaml
```

Add the following:

```
--oidc-issuer-url=https://dex.example.com:32000
--oidc-client-id=example-app
--oidc-ca-file=/etc/ssl/certs/openid-ca.pem
--oidc-username-claim=email
--oidc-groups-claim=groups
```

#### Managed Way (kube-oidc-proxy)

< Need to correct this process >

### 5. Validate K8s auth

Repeat the authentication steps from before. Get the page (http://127.0.0.1:5555) where you see
an ID Token JWT, Access Token JWT, Claims payload.

This time create a new kubeconfig based off the following template:

```
apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: {{ base64 encoded CA for Kube if self hosted (or ssl/ca.pem for kube-oidc-proxy) }}
    server: https://{{ Kube API server (or externally accessible kube-oidc-proxy service ) }}
  name: kubernetes
contexts:
- context:
    cluster: kubernetes
    namespace: default
    user: {{ OIDC email (mmiller@example.com) or whatever you like }}
  name: default
current-context: default
kind: Config
preferences: {}
users:
- name: {{ OIDC email (mmiller@example.com) or whatever you like }}
  user:
    token: {{ ID Token returned in 127.0.0.1:5555 }}
```

Or

```
$ token={{ OIDC ID TOKEN }}
$ curl -H "Authorization: Bearer $token" -k https://{{ API server }}/api/v1/nodes
```

In both cases you will send up seeing a message that resembles failure!

```
nodes is forbidden: User \"mmiller@example.com\" cannot list resource \"nodes\" in API group \"\" at the cluster scope
```

This is a very important point. Remember dex provides AUTHENTICATION it does not provide AUTHORIZAITON. 

Fear not this is easy to remedy in simple or more complex ways. See `7.`


### 6. A better kubeconfig

I provided the previous kubeconfig to show default behavior. We don't actually want to use that kubeconfig.
It will expire in 12 hours and the user must do the entire auth song and dance again.

We can make a better kubeconfig that natively refreshes the user with the [OpenID connect strategy](https://kubernetes.io/docs/reference/access-authn-authz/authentication/#openid-connect-tokens).

This time create a kubeconfig that looks like:

```
apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: {{ base64 encoded CA for Kube if self hosted (or ssl/ca.pem for kube-oidc-proxy) }}
    server: https://{{ Kube API server (or externally accessible kube-oidc-proxy service ) }}
  name: kubernetes
contexts:
- context:
    cluster: kubernetes
    namespace: default
    user: {{ OIDC email (mmiller@example.com) or whatever you like }}
  name: default
current-context: default
kind: Config
preferences: {}
users:
- name: {{ OIDC email (mmiller@example.com) or whatever you like }}
  user:
    auth-provider:
      config:
        id-token: {{ ID Token returned in 127.0.0.1:5555 }}
        client-id: example-app
        client-secret: ZXhhbXBsZS1hcHAtc2VjcmV0
        idp-issuer-url: https://dex.example.com:32000
        refresh-token: {{ Refresh Token returned in 127.0.0.1:5555 }}
```

Remember `client-secret` is the default OAuth2 client secret from `example-app`. You will want this random
string different if you make a custom app.

### 7. Basic Authorization with oidc-groups

I was very particular giving multiple teams groups in LDAP. We want some sort of Authorization in place
and surly a home to authorize to.

The example can be ran here:

```
$ kubectl apply -f misc/teams
```

This will create all the teams matched to rbac groups of their OIDC group which is granted by memberOf in LDAP.

``` yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: rolebinding-hephaestus-projects
  namepace: hephaestus-projects
subjects:
- kind: Group
  name: hephaestus
  apiGroup: rbac.authorization.k8s.io
# FOOBAR-1337 - Embedded into team to help complete
# Web UI changes. END 24/06/2020
- kind: User
  name: ecarter@example.com
  apiGroup: rbac.authorization.k8s.io
```

In the hephaestus team we can see how they might treat embedding a teammate from another team. This can
be handled by a PR and then deployed with ArgoCD.

### Categorized Notes:

* Remember dex doesn't poll the config file. If you change and apply it, bounce dex.
* Multi cluster auth can be done with something like [gangway](https://github.com/heptiolabs/gangway)
* dex docs: https://github.com/dexidp/dex/tree/master/Documentation
* You can inspect JWTs by base64 decoding each section aaa.bbb.ccc (`echo -n "bbb" | base64 --decode`)
* Or if inspect JWTs at jwt.io
* Cool authorization tools: `kubectl auth can-i`, `rakkess`, `kubectl-who-can`, `rbac-lookup`