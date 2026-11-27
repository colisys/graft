# M0：Intel Mac 平台基线

从仓库根目录运行：

```sh
python3 docs/sclereid/m0/sclereid-m0.py
```

| 处理器 | macOS | QEMU | 结果 |
|---|---|---|---|
| Intel i5-3210M | 13.7.8 | 11.1.2 | 通过 |
| Intel i9-9980HK | 14.8.9 | 11.1.3 | 通过 |

两台机器均强制使用 HVF，校验 Alpine virt 3.22.2 镜像和来宾串口标记，执行 QMP `quit` 后退出码为 0。
