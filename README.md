# 🏭 Node-RED Edge Store & Forward (Industrial Edition)

**基于 Node-RED + SQLite 的工业级边缘存储转发框架（高鲁棒性版）**

这是一个面向工业现场、资源受限网关的**“断点续传”**解决方案。它解决了边缘计算中常见的网络不稳定、PLC 通讯超时、磁盘空间膨胀等痛点，确保数据在采集、缓存、转发全链路中**零丢失、有序、可追溯**。

---

## 🌟 核心特性 (v2.0 迭代更新)

相较于最初的精简版，当前版本经过深度优化，具备以下工业级特性：

1. **🛡️ 防御性采集 (Robust Ingestion)**
* 内置空值/错误拦截机制，防止 Modbus/S7 通讯超时产生的无效数据污染数据库。
* 采用 **SQL 字符串模板拼接** 技术，彻底解决 `msg` 对象元数据污染导致的 `SQLITE_CONSTRAINT` 写入报错。


2. **🔌 智能断网熔断 (Circuit Breaker)**
* 引入 **MQTT 连接感知** 机制。
* 当云端连接断开时，自动停止数据库轮询，防止系统陷入“捞取-失败-重捞”的死循环，保护网关 CPU 资源。


3. **🌏 北京时间对齐 (Timezone Alignment)**
* 摒弃难以阅读的 Unix 毫秒戳，入库时自动转换为 **北京时间 (UTC+8)** 格式 (`YYYY-MM-DD HH:mm:ss`)。
* 方便运维人员直接通过 DataGrip 或 SQL 工具排查故障。


4. **🧹 自动磁盘运维 (Auto-Maintenance)**
* 内置每日凌晨自动清理脚本，支持自定义保留天数（`RETENTION_DAYS`）。
* 集成 `VACUUM` 指令，强制回收 SQLite 删除数据后产生的磁盘碎片，防止存储空间无限膨胀。



---

## 📂 文件说明

* `flows_store_forward.json`: 核心 Node-RED 流程文件（直接导入即可使用）。
* `sqlite-init.sql`: 数据库初始化脚本（流程首次运行时亦可自动建表）。
* `TROUBLESHOOTING.md`: **[强烈推荐]** 详细记录了开发过程中的踩坑经验与故障复盘（包含 Modbus 报错、死循环、时区问题的深度解析）。

---

## 🔄 流程逻辑概览

### 1. 入库链路 (Ingestion)

> **Modbus/S7 Read** ➔ **清洗与格式化** ➔ **SQLite Insert**

* **清洗**：拦截通讯超时的空 Payload。
* **格式化**：生成北京时间戳，将数据包封装为 JSON 字符串。
* **存储**：以 `status='pending'` 状态写入 `message_queue` 表。

### 2. 出库链路 (Forwarding)

> **MQTT 状态监听** ➔ **断路器判断** ➔ **批量查询** ➔ **逐条发送** ➔ **状态更新**

* **断路器**：若 MQTT 未连接，流程直接终止，不查询数据库。
* **发送**：连接正常时，按 `id ASC` 顺序取出旧数据推送到云端。
* **确认**：发送成功后，立即执行 `UPDATE` 将状态改为 `sent`。

### 3. 运维链路 (Maintenance)

> **Cron 触发** ➔ **过期删除** ➔ **VACUUM 压缩**

* 每天凌晨 02:00 删除 `N` 天前的 `sent` 数据，并释放磁盘空间。

---

## ⚙️ 环境配置 (Environment)

| 变量名 | 默认值 | 说明 |
| --- | --- | --- |
| `DB_PATH` | `/data/store.db` | SQLite 数据库文件路径 |
| `MQTT_HOST` | `localhost` | MQTT Broker 地址 |
| `MQTT_PORT` | `1883` | MQTT Broker 端口 |
| `RETENTION_DAYS` | `7` | **[新增]** 历史数据保留天数，超过此时限的已发送数据将被自动清理 |
| `BATCH_LIMIT` | `10` | 单次轮询的最大条数（控制内存水位） |

---

## 🚀 快速开始

### 1. 依赖安装

在 Node-RED 的 Palette 中安装以下核心节点：

* `node-red-node-sqlite` (数据库驱动)
* `node-red-contrib-modbus` (或你需要的 S7/OPC-UA 插件)

### 2. 导入流程

1. 下载本仓库的 `flows_store_forward.json`。
2. 在 Node-RED 右上角菜单选择 **导入 (Import)** -> **粘贴内容**。

### 3. 关键配置检查 (必做!)

* **配置数据库**：双击 SQLite 节点，设置你的 `.db` 文件存储路径。
* **配置 MQTT**：在 `发送到云端` 节点中配置你的 Broker 地址。
* **关联状态监听 (重要)**：
* 找到流程中的 **“监听 MQTT 状态”** (Status) 节点。
* 双击它，确保在 **Target (目标)** 中勾选了 **“发送到云端”** 节点。
* *注：导入流程时 ID 可能会变，若未关联会导致熔断机制失效。*



### 4. 部署运行

点击 **Deploy**。观察 Debug 窗口：

* ✅ **入库成功**：显示 PLC 采集到的数据。
* ✅ **网络正常**：显示“正在轮询”，数据会被转发。
* 🚫 **断网测试**：断开 MQTT 连接，Debug 应提示“MQTT断开，暂停补发”，且停止数据库查询（无死循环刷屏）。

---

## 📚 常见问题 (FAQ)

### Q1: 为什么删除了数据，.db 文件大小没变？

**A**: 这是 SQLite 的特性。删除数据仅标记空间为“空闲”。本项目已在清理脚本中集成了 `VACUUM` 命令，每天凌晨会自动压缩并释放空间。

### Q2: 为什么 ID 不是从 1 开始的？

**A**: `AUTOINCREMENT` 机制为了保证数据唯一性，不会回溯 ID。这是工业系统的标准设计，请勿强制重置，以免日志溯源冲突。

### Q3: 遇到 Modbus 超时报错 `SQLITE_CONSTRAINT` 怎么办？

**A**: 请检查你是否使用了最新版的流程代码。新版已在入库前增加了空值拦截逻辑 `if (!msg.payload) return null;`。

> 更多深度技术细节，请阅读仓库内的 [TROUBLESHOOTING.md](https://www.google.com/search?q=./TROUBLESHOOTING.md)。
