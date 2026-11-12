# 内存失效扰动抑制：现有内核接口版本

本版本在运行中的目标 RISC-V Linux 内核上构建外部模块。模块逐页调用
`alloc_page(GFP_KERNEL | __GFP_ZERO)`，用 `vm_insert_page()` 把本会话的页面
映射给 memtester。发现异常时提交真实字节偏移，测试进程退出、映射关闭后，
模块把该页的分配引用留在隔离表中。**“模块扣留”仅表示本模块持有分配页，
不是 Linux 内核的 HWPoison 或永久物理坏页下线。**重启会清空隔离表。
这条路径不依赖 `CONFIG_MEMORY_FAILURE`，也不扫描或申请任意指定 PFN。
旧的任意 PFN 扫描范围需要单独评估。

## 1 编译驱动

目标机须有与 `uname -r` 完全匹配的内核头文件、配置和 `Module.symvers`，
以及 C 编译工具、`make`、`modinfo`、`nm` 和 Python 3。从包含本 README 的
项目根目录开始，按顺序执行。

~~~bash
# 进入驱动源码目录。
cd rampage/module

# 查看服务器正在运行的内核版本。
uname -r

# 清理上次生成的对象，用当前内核的构建目录编译模块。
make clean
make > build.log 2>&1
cat build.log

# 查看新模块的内核版本标识。
modinfo -F vermagic ./phys_mem.ko

# 查看模块依赖的内核符号。
nm -u ./phys_mem.ko

# 保存运行内核、模块信息和文件校验值。
uname -a > build-info.txt
modinfo ./phys_mem.ko >> build-info.txt
sha256sum ./phys_mem.ko >> build-info.txt
~~~

检查 `build.log` 中的 modpost 输出。模块的 `vermagic` 应以 `uname -r`
显示的版本开头。依赖列表中应没有 `mm_page_order`、`mm_buddy_expand`、
`memory_failure` 和 `SetPageHWPoison`。

## 2 加载驱动

仍在 `rampage/module` 目录执行。

~~~bash
# 查看当前是否已加载 phys_mem。
lsmod | grep phys_mem
~~~

如果查到了旧模块，先结束测试并处理已扣留的页，再卸载旧模块。隔离表仍有扣留页时，模块会拒绝卸载。

~~~bash
# 已加载旧模块时执行。
sudo rmmod phys_mem
~~~

~~~bash
# 加载刚编译的模块。
sudo insmod ./phys_mem.ko

# 确认设备节点已经生成。
ls -l /dev/phys_mem

# 回到项目根目录。
cd ../..
~~~

## 3 编译 memtester

~~~bash
# 进入 memtester 源码目录并编译。
cd memtester-master
make

# 回到项目根目录。
cd ..
~~~

下一步直接调用 `memtester-master/memtester`。设备节点默认权限为 `0600`，
测试、查询和恢复命令使用 `sudo`。

## 4 运行四项测试并查看隔离结果

先与第三方确认：在**现有内核**上，以测试进程退出后模块仍持有目标 PFN、
且用户态映射数为零，作为隔离判据。下面用 `2026111201` 作为示例批次号。
新开一批时，把测试、查询、恢复命令和日志路径中的编号换成同一个新编号。

~~~bash
# 建立本次测试的日志目录。
mkdir -p test-results/2026111201

# 先跑无注入基线，再用刚编译的 memtester 跑四项用例。
sudo python3 rampage/userspace/main.py \
    --run-id 2026111201 \
    --memtester ./memtester-master/memtester \
    --output-dir test-results/2026111201

# 测试结束后，查询并保存驱动的隔离记录。
sudo ./rampage/userspace/phys_memctl status --run-id 2026111201 \
    > test-results/2026111201/isolation-status.txt
cat test-results/2026111201/isolation-status.txt
~~~

默认每轮分配 8 页，在从 0 开始计数的第 5 号页注入。

`summary.json` 记录每轮会话、注入类型、PFN、检测端实际字节偏移、隔离表
确认结果和下一轮分配探针。每轮独立的 `.log` 保存 memtester 的注入日志与
检测结果。程序把执行异常（退出码含 `1`、结果不完整、设备协议不匹配）
作为测试失败，而内存校验失败（退出码 `2/4/6`）作为可定位检测结果。
无效注入记录原因并补做；已生效却未检测、定位或隔离成功的注入仍计入
分母。脚本计算 `成功拦截 / 有效注入`，四项分别要求 `5/5`、`3/3`、
`2/2`、`5/5`，对应大纲编号：

| 大纲编号 | 注入类型 | 有效注入次数 |
| --- | --- | ---: |
| 3-3-0006 | 1 地址校验 | 5 |
| 3-3-0007 | 3、4、5 位模式校验 | 各 1 |
| 3-3-0008 | 2、6 运算比较校验 | 各 1 |
| 3-3-0009 | 7 字节写入校验 | 5 |

memtester 在驱动映射的缓冲区上运行，同时在普通用户态内存中独立生成
各测试的预期数据。结果协议包含 `session_id`、错误类型、真实字节偏移、
出错侧、预期值和实测值。每页首次报错后停止读写该页。仅当检测类型、A 侧
字节偏移及预期值和实测值与注入前后读值一致、且同页没有其他异常证据时，
才标为“软件注入已确认”。异常退出时，已完整写出的检测结果按“来源不明”
提交，已确认生效的注入仍计入分母。驱动只接受本会话页索引，
验证偏移边界，并返回 PFN 供核对。查询结果的 `module_refs=1` 和
`map_refs=0` 是模块扣留且映射已清空的证据。

## 5 取证后按批次恢复

全部测试会话退出、保存隔离记录后，在项目根目录执行。命令中的
`2026111201` 应与本次测试的批次号一致。

~~~bash
# 恢复本批次确认由软件注入导致的隔离页，并保存恢复结果。
sudo ./rampage/userspace/phys_memctl restore --run-id 2026111201 --simulated-only \
    > test-results/2026111201/restore.log 2>&1
cat test-results/2026111201/restore.log

# 查看恢复后的状态，确认模拟隔离页数为 0。
sudo ./rampage/userspace/phys_memctl status --run-id 2026111201 \
    > test-results/2026111201/status-after-restore.txt
cat test-results/2026111201/status-after-restore.txt
~~~

恢复命令只释放该批次标为“软件注入已确认”、且无额外页引用的隔离页。
来源不明的页继续扣留。命令报告 `released`、`retained`、`failed`、
`already_released`；失败条目留在表中，`last_error` 给出负 errno，可重试。
重复恢复会跳过已释放条目。核验状态中的 `simulated=0`，保留全部日志。

隔离表和页池有可在加载模块时设置的容量参数。分配时为每个在测页预留隔离
容量，记录容量包含已恢复条目。容量不足时拒绝新分配。重启后隔离表清空，
须重新检测。旧版任意 PFN 扫描范围需单独评估。

交付时收集目标机上生成的 `phys_mem.ko`、`memtester`、配套工具和运行
脚本、`build-info.txt`、`build.log`、完整批次日志及恢复前后的状态输出。
# Failure_disturbance_suppression-depent
# Failure_disturbance_suppression-depent
