+++
date = '2025-10-10T15:59:17+08:00'
draft = false
title = '在K8s中部署openLDAP'
tags = ["LDAP", "Kubernetes"]
categories = ["经验"]
showToc = true
math = false

+++

## 安装

先创建一个命名空间：`kubectl create namespace authen`

1. 设置PVC：

   ```yaml
   # vi openldap-pvc.yaml
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: ldap-data-pvc
     namespace: authen
   spec:
     accessModes:
     - ReadWriteOnce
     resources:
       requests:
         storage: 10Gi
     storageClassName: local-path
   ---
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: ldap-config-pvc
     namespace: authen
   spec:
     accessModes:
     - ReadWriteOnce
     resources:
       requests:
         storage: 10Gi
     storageClassName: local-path
   ```

   执行`kubectl apply -f open-ldap-pvc.yaml`创建PVC即可

2. 设置初始化时需要插入的信息：

   ```yaml
   # vi ldap-init.ldif
   dn: ou=People,dc=example,dc=com
   ou: People
   objectClass: organizationalUnit
   
   dn: ou=Group,dc=example,dc=com
   ou: Group
   objectClass: organizationalUnit
   ```

   执行`kubectl create configmap openldap-init --from-file=./ldap-init.ldif -n authen`生成ConfigMap，供之后LDAP初始化时读取

3. 创建部署文件：

   ```yaml
   # vi openldap-deployment.yaml
   kind: Deployment
   apiVersion: apps/v1
   metadata:
     name: openldap
     namespace: authen
     labels:
       app: openldap
     annotations:
       app.kubernetes.io/alias-name: LDAP
       app.kubernetes.io/description: 认证中心
   spec:
     replicas: 1
     selector:
       matchLabels:
         app: openldap
     template:
       metadata:
         labels:
           app: openldap
       spec:
         containers:
           - name: go-ldap-admin-openldap
             args:
               - --copy-service
             image: 'osixia/openldap:1.5.0'
             ports:
               - name: tcp-389
                 containerPort: 389
                 protocol: TCP
               - name: tcp-636
                 containerPort: 636
                 protocol: TCP
             env:
               - name: TZ
                 value: Asia/Shanghai
               - name: LDAP_ORGANISATION
                 value: "orgldap"
               - name: LDAP_DOMAIN
                 value: "example.com"
               - name: LDAP_ADMIN_PASSWORD
                 value: "123456"
               - name: LDAP_BACKEND
                 value: mdb
             resources:
               limits:
                 cpu: 500m
                 memory: 500Mi
               requests:
                 cpu: 100m
                 memory: 100Mi
             volumeMounts:
               - name: ldap-config-pvc
                 mountPath: /etc/ldap/slapd.d
               - name: ldap-data-pvc
                 mountPath: /var/lib/ldap
               - name: openldap-init
                 mountPath: /container/service/slapd/assets/config/bootstrap/ldif/custom/init.ldif
                 subPath: init.ldif
         volumes:
           - name: ldap-config-pvc
             persistentVolumeClaim:
               claimName: ldap-config-pvc
           - name: ldap-data-pvc
             persistentVolumeClaim:
               claimName: ldap-data-pvc
           - name: openldap-init
             configMap:
               name: openldap-init
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: openldap-svc
     namespace: authen
     labels:
       app: openldap-svc
   spec:
     ports:
     - name: tcp-389
       port: 389
       protocol: TCP
       targetPort: 389
     - name: tcp-636
       port: 636
       protocol: TCP
       targetPort: 636
     selector:
       app: openldap
   ```

   执行`kubectl apply -f ldap-deployment.yaml`即可将LDAP部署为一个Pod

执行以下命令查看各配置是否生效：

```bash
# Pod创建情况
master@master:~/authen/ldap$ kubectl get pods -n authen
NAME                        READY   STATUS    RESTARTS   AGE
openldap-6954f7b8bc-2tmdh   1/1     Running   0          22m
# Service运行情况
master@master:~/authen/ldap$ kubectl get svc -n authen
NAME           TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)           AGE
openldap-svc   ClusterIP   10.244.30.165   <none>        389/TCP,636/TCP   21m
# PVC创建情况
master@master:~/authen/ldap$ kubectl get pvc -n authen
NAME              STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
ldap-config-pvc   Bound    pvc-539fd3b7-12ed-488b-9c86-59e07de28b05   10Gi       RWO            local-path     37m
ldap-data-pvc     Bound    pvc-63a03d24-f078-43af-ae6c-0ce2328ba54e   10Gi       RWO            local-path     37m
```

---

创建临时测试Pod并进入命令行：

```bash
kubectl run -it --rm ldap-client --image=osixia/openldap --namespace authen -- bash
```

执行测试：

```bash
ldapsearch -x -H ldap://openldap-svc.authen:389 -b dc=example,dc=com -D "cn=admin,dc=example,dc=com" -w 123456
# extended LDIF
#
# LDAPv3
# base <dc=example,dc=com> with scope subtree
# filter: (objectclass=*)
# requesting: ALL
#

# example.com
dn: dc=example,dc=com
objectClass: top
objectClass: dcObject
objectClass: organization
o: orgldap
dc: example

# search result
search: 2
result: 0 Success

# numResponses: 2
# numEntries: 1
```

