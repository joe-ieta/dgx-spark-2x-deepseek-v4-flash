# GB10 双节点 NCCL / RoCE / GPUDirect RDMA 问题调查总结

## 一、遇到的问题

在两台 NVIDIA GB10 节点之间测试 NCCL 多机通信时，发现：

NCCL 日志显示：

    Connected all rings, use ring PXN 0 GDR 0

其中：

    GDR 0

表示：

    GPUDirect RDMA 没有启用

也就是说，目前 NCCL 可以使用 RDMA 网络通信，但是 GPU 显存没有直接通过 RDMA NIC 访问。

当前实际通信路径：

    GPU 显存
       |
       |
    CPU/System Memory
       |
       |
    RDMA NIC
       |
       |
    RoCE 网络
       |
       |
    对端 GPU


理想通信路径：

    GPU 显存
       |
       |
    GPUDirect RDMA
       |
       |
    RDMA NIC DMA
       |
       |
    RoCE 网络
       |
       |
    对端 GPU


---

# 二、环境信息

双节点：

Node 1:
    ieta-spark01

Node 2:
    ieta-spark02


硬件：

    NVIDIA GB10 GPU


软件：

    Ubuntu 24.04

    Kernel:
    6.17.0-1031-nvidia

    NVIDIA Driver:
    580.173.02

    CUDA:
    13.0

    NCCL:
    2.31.2+cuda13.3


网络：

    RoCE

    RDMA Device:
    roceP2p1s0f1

    GID:
    3


---

# 三、已经确认正常的部分


## 1. GPU 驱动正常

nvidia-smi 正常：

    NVIDIA GB10

驱动：

    580.173.02


CUDA 工作正常。


---

## 2. RDMA 网络正常


测试：

    ib_write_bw


结果：

    BW average:
    12997 MB/sec


约：

    13 GB/s


说明：

- RoCE 网络正常
- Mellanox RDMA 通信正常
- Queue Pair 正常
- NIC 带宽正常


---

## 3. NCCL 多机通信正常


运行：

    mpirun
    ieta-spark01
    ieta-spark02


测试：

    all_reduce_perf


结果：

    Avg bus bandwidth:
    12.8395 GB/s


说明：

- MPI 正常
- NCCL 初始化正常
- 两节点 GPU 通信正常
- IB/RoCE transport 正常


---

# 四、调查 nvidia_peermem


发现：

模块文件存在：


    modinfo nvidia_peermem


显示：

    /lib/modules/6.17.0-1031-nvidia/kernel/nvidia-580-open/nvidia-peermem.ko


版本：

    580.173.02


但是加载失败：


    sudo modprobe nvidia_peermem


返回：


    modprobe:
    ERROR: could not insert 'nvidia_peermem':
    Invalid argument


两个节点完全相同。


同时：

    /dev/nvidia-peermem


不存在。


说明：

传统 NVIDIA GPUDirect RDMA 依赖的：

    nvidia_peermem

没有成功启用。


---

# 五、进一步分析结果


## 1. 不是网络问题

原因：

ib_write_bw 达到：

    13 GB/s


说明：

RoCE 链路没有问题。


---

## 2. 不是 NCCL 配置问题


NCCL 已经：

- 找到 GPU
- 找到 RDMA NIC
- 使用 IB transport
- 完成 AllReduce


日志：

    NET/IB : Using roceP2p1s0f1


说明 NCCL 配置正确。


---

## 3. 不是 Mellanox 驱动问题


mlx5 模块正常：

    mlx5_core

    mlx5_ib

    ib_uverbs

    ib_core


---

# 六、真正的问题定位


问题集中在：

    GB10 + NVIDIA 580 Driver + 当前 Kernel

之间的：

    GPUDirect RDMA 支持


GB10 与传统 GPU 不同：

例如：

- A100
- H100
- L40


这些 GPU 通常使用：

    nvidia_peermem


但是 GB10 是：

    Grace Blackwell 架构


系统显示：

    GPU C2C Mode: Enabled


属于 GPU-CPU 高速一致性架构。


因此：

传统 A100/H100 的 nvidia_peermem 排查方法不一定适用。


---

# 七、最终解决方案


## 当前阶段：

停止继续折腾：

    nvidia_peermem


因为：

- 模块存在
- 但是无法加载
- 没有明确错误日志
- GB10 架构可能不走传统路径


采用当前已经工作的方案：


    NCCL + RoCE + IB Transport


当前性能：

    AllReduce:
    ~12.8 GB/s


这个性能已经可以支持：

- 分布式推理
- 分布式训练
- Benchmark


---

# 八、后续如果需要进一步优化


未来可以研究：

1. NVIDIA GB10 官方 GPUDirect RDMA 支持方式

2. DMA-BUF GPU memory registration

3. NVIDIA GB10 专用 NCCL 调优

4. NVIDIA Driver/Firmware 更新

5. NVIDIA 官方 GB10 网络配置建议


不要直接套用：

    A100/H100 nvidia_peermem

教程。


---

# 九、最终状态总结


当前集群：

GPU:

    NVIDIA GB10


网络:

    RoCE


NCCL:

    IB transport enabled


GPUDirect RDMA:

    Disabled


实际性能：

    ≈13 GB/s


最终结论：

双节点 GB10 集群已经正常工作。

目前唯一缺失的是：

    GPUDirect RDMA 加速


这个不会阻止继续使用 NCCL 分布式任务。

当前方案已经稳定，可以继续推进后续 DeepSeek / vLLM / 分布式任务部署。

后续优化目标应该转向：

    GB10 专用 GDR 支持

而不是继续排查传统 nvidia_peermem。
