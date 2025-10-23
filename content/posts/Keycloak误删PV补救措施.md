+++
date = '2025-10-23T11:08:21+08:00'
draft = false
title = 'Keycloak误删PV补救措施'
tags = ["Keycloak", "debug"]
categories = ["Keycloak学习"]
showToc = true
math = false

+++

## 背景

K8s中的插件`local-path-provisioner`能够动态创建PV，使用`local-path`PV时，无需手动建立PV，只需建立一个PVC，在其中指定`storageClassName: local-path`即可，插件会自动为其分配PV和存储目录

这个插件的好处是：

1. 用户无需手动配置PV，只需创建PVC绑定即可；
2. 在非文件共享的场景下，用户也无需关心服务Pod被调度至哪个节点，因为插件会自动根据Pod所在节点分配存储区

**现在我误删了所有PV**，结果是执行`kubectl get pv`命令时，看到了状态是`Terminating`的PV，这说明PV处于*正在被删除*的状态

但当我执行命令`kubectl get pvc -n authen`查看PVC时，却发现绑定了PV的PVC是正常`Bound`的状态

## 原因分析

之所以被删除时的PV表现为`Terminating`状态而非直接消失，是因为该PV存在**`finalizer`字段**，这个字段的作用就是在集群删除PV时，不立刻清除PV，而是将其标记起来，呈现`Terminating`状态，这是为了**确保一些重要的清理动作在资源被物理删除前完成**，此时，PVC仍然是可用的

我现在存在两个`Terminating`状态的PV，它们各自的名称是：

```bash
pvc-539fd3b7-12ed-488b-9c86-59e07de28b05
pvc-63a03d24-f078-43af-ae6c-0ce2328ba54e
```

查看其中一个PV的信息：

```bash
master@master:~/authen/pvc$ kubectl get pv pvc-539fd3b7-12ed-488b-9c86-59e07de28b05 -o yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  annotations:
    local.path.provisioner/selected-node: master
    pv.kubernetes.io/provisioned-by: rancher.io/local-path
  creationTimestamp: "2025-10-10T07:46:40Z"
  deletionGracePeriodSeconds: 0
  deletionTimestamp: "2025-10-22T06:34:12Z"
  finalizers:
  - kubernetes.io/pv-protection
  name: pvc-539fd3b7-12ed-488b-9c86-59e07de28b05
  resourceVersion: "30449839"
  uid: bea50dbb-7f29-4e21-bb22-d9e61ce13cec
spec:
  accessModes:
  - ReadWriteOnce
  capacity:
    storage: 10Gi
  claimRef:
    apiVersion: v1
    kind: PersistentVolumeClaim
    name: ldap-config-pvc
    namespace: authen
    resourceVersion: "27503744"
    uid: 539fd3b7-12ed-488b-9c86-59e07de28b05
  hostPath:
    path: /opt/local-path-provisioner/pvc-539fd3b7-12ed-488b-9c86-59e07de28b05_authen_ldap-config-pvc
    type: DirectoryOrCreate
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - master
  persistentVolumeReclaimPolicy: Delete
  storageClassName: local-path
  volumeMode: Filesystem
status:
  phase: Bound

```

可以看到，在`metadata`下确实存在`finalizers`字段，正是它导致了PV始终处于`Terminating`状态

## 解决

**整体思路：删除指令已经下达，所以只能先使删除成功完成，接着重建PV和PVC**

### 删除PV和失效PVC

通过删除PV的`finalizer`字段，完成对该PV的删除动作：

```bash
kubectl patch pv pvc-539fd3b7-12ed-488b-9c86-59e07de28b05 -p '{"metadata":{"finalizers":null}}'
# 或可手动编辑：kubectl edit pv pvc-539fd3b7-12ed-488b-9c86-59e07de28b05
```

执行后可使用`kubectl get pv`检查，确认该PV已被删除

使用相同的方法删除另一个PV：`pvc-63a03d24-f078-43af-ae6c-0ce2328ba54e`

---

完成后，查看PVC，可能会看到先前的PVC已是`Lost`状态：

```bash
master@master:~/authen/pvc$ kubectl get pvc -n authen
NAME                   STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
ldap-config-pvc        Lost     pvc-539fd3b7-12ed-488b-9c86-59e07de28b05   0                         local-path     12d
ldap-data-pvc          Lost     pvc-63a03d24-f078-43af-ae6c-0ce2328ba54e   0                         local-path     12d
```

此时再将这两个失效的PVC清除，类似于删除PV，同样需要删去`finalizer`字段，以删除`ldap-data-pvc`为例：

```bash
master@master:~/authen/pvc$ kubectl delete pvc ldap-data-pvc -n authen --force --grace-period=0
master@master:~/authen/pvc$ kubectl patch pvc ldap-data-pvc -n authen -p '{"metadata":{"finalizers":null}}'
```

{{< admonition tip "提示" >}}如果PV被删除后PVC变为`Pending`状态，则可以无需删除PVC，这是因为此时PVC处于等待PV的状态，只要重建PV，就可以立刻进行绑定，从而恢复正常{{< /admonition >}}

### 重建PV

{{< admonition note "注意" >}}

当我完成全部的修复工作后，发现似乎从理论上来说不需要重建PV这一步，这是因为只要`local-path-provisioner`插件仍在运行，只需要重新创建一次PVC，需要的PV就会自动生成了。但我仍然将重建PV这一步写在这里，主要有两个原因：

1. 我原本的恢复步骤就是这样做的
2. 似乎不能保证自动生成的新PV仍然指向原本的节点或目录，如果指向了新的节点或目录，可能导致服务数据丢失

{{< /admonition >}}

通过手动创建指向原目录的PV重建删除的PV，以重建`pvc-539fd3b7-12ed-488b-9c86-59e07de28b05`为例，这个PV原本指向master节点的`/opt/local-path-provisioner/pvc-539fd3b7-12ed-488b-9c86-59e07de28b05`目录，绑定至名为`ldap-config-pvc`的PVC，命名空间为`authen`：

创建`reclaim.yaml`：

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pvc-539fd3b7-12ed-488b-9c86-59e07de28b05  # 酌情修改
spec:
  capacity:
    storage: 10Gi
  accessModes:
    - ReadWriteOnce
  storageClassName: local-path
  persistentVolumeReclaimPolicy: Delete
  local:
    path: /opt/local-path-provisioner/pvc-539fd3b7-12ed-488b-9c86-59e07de28b05  # 酌情修改
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - master  # 酌情修改
  claimRef:
    namespace: authen  # 酌情修改
    name: ldap-config-pvc  # 酌情修改

```

然后执行`kubectl apply -f reclaim.yaml`即可，执行`kubectl get pv`查看是否已经重建，此时的PV还没有绑定PVC，所以状态应该是`Available`

相同的操作，重建`pvc-63a03d24-f078-43af-ae6c-0ce2328ba54e`这个PV

都完成后，应该能看到两个PV都是`Available`的状态

### 重建PVC

重新执行初次建立PVC时的`yaml`文件即可，例如：

```yaml
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

如此一来，查看PVC状态可以看到`Bound`状态的PVC：

```bash
master@master:~/authen/pvc$ kubectl get pvc -n authen
NAME                   STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
ldap-config-pvc        Bound    pvc-539fd3b7-12ed-488b-9c86-59e07de28b05   10Gi       RWO            local-path     2s
ldap-data-pvc          Bound    pvc-63a03d24-f078-43af-ae6c-0ce2328ba54e   10Gi       RWO            local-path     3s
```

此时，重建的两个PV的状态也应从`Available`变为`Bound`，修复完成
