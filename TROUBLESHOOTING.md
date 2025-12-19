# 🛠️ 边缘转发系统故障记录 (Troubleshooting Log)

本项目记录了在开发 Node-RED 边缘存储转发框架过程中遇到的核心问题及解决方案。

---

## 01. Modbus 超时导致数据库写入失败 (SQLITE_CONSTRAINT)

### 1. 问题描述
在运行 Node-RED 边缘采集流程时，由于 PLC 或 Modbus 仿真器未启动，`Modbus-Read` 节点触发了超时错误。此时，调试窗口（Debug）抛出以下异常：

> **Error**: `SQLITE_CONSTRAINT: NOT NULL constraint failed: message_queue.topic`

虽然 PLC 通讯失败是预料中的，但该错误意外导致了下游数据库节点崩溃，并在某些极端情况下存入了无效的空记录。

---

### 2. 原因分析

* **空消息触发**：`Modbus-Read` 节点配置了 `Empty msg on fail`。当通讯超时时，它仍会向下游发送一条消息，此时 `msg.payload` 为空字符串 `""`。
* **字段约束冲突**：数据库表 `message_queue` 的 `topic` 字段设置了 `NOT NULL` 约束，无法接受空值。
* **参数绑定失效**：
    * **现象**：虽然在函数节点中设置了 `msg.params` 进行参数绑定，但由于上游 Modbus 节点输出的消息对象极其**臃肿**（包含了 `buffer`、`input` 等复杂对象元数据）。
    * **根因**：`node-red-node-sqlite` 节点在解析 `?` 占位符时，由于 `msg` 对象层级过深或受元数据干扰，发生了映射偏移或解析失败。
    * **结果**：SQLite 驱动认为第一个参数（topic）是 `NULL`，从而触发了约束报错。



---

### 3. 解决方案

为了提高系统的健壮性，我们采取了“逻辑拦截”+“指令重构”的双重方案：

#### A. 增加入库前的“过滤网”
在 `清洗 & 组装` Function 节点开头增加防御性代码，确保只有有效的数据才能进入存储环节。如果通讯异常，直接丢弃该条消息。

```javascript
// --- 防御性编程：拦截无效数据 ---
if (msg.payload === "" || msg.payload == null || msg.error) {
    return null; // 彻底避免空值进入下游数据库节点
}
B. 放弃参数绑定，改用字符串拼接
为了规避臃肿消息对象对 msg.params 的干扰，我们将 SQL 语句改为直接拼接模式。

JavaScript

// 核心改动：使用模板字符串直接将变量拼入 SQL
msg.topic = `INSERT INTO message_queue (topic, payload, qos, ts, status, retries) 
             VALUES ('${topicStr}', '${payloadStr}', ${qos}, '${now}', 'pending', 0)`;

// 彻底删除可能干扰 SQLite 节点的 params 对象
delete msg.params; 
4. 经验总结 (Lessons Learned)
边缘侧的防御性编程：在处理硬件采集数据时，永远不要假设上游节点总是输出有效数据。必须在入库前进行有效性校验。

化繁为简：当 Node-RED 消息对象 (msg) 变得过于复杂时，msg.params 这种依赖对象解析的传参方式容易在高并发或复杂元数据环境下失效。

确定性指令：在工业边缘场景下，“暴力拼接 SQL 字符串” 虽然看起来不够“优雅”，但它提供了最高的确定性和稳定性，是解决数据库写入异常的最直接手段。

## 02. 断网环境下的 MQTT 补发死循环 (Logic Loop)

### 1. 问题描述
在测试断网重传逻辑时发现：当 MQTT Broker（云端）连接断开时，系统会陷入死循环，在调试窗口疯狂刷出重复的旧数据。即使网络恢复，系统也积压了大量重复指令，导致云端数据混乱。

---

### 2. 原因分析

* **并行逻辑陷阱**：原本的逻辑是“先通过 MQTT 发送数据”与“更新数据库状态为 `sent`”并行执行。
* **状态更新失效**：当网络断开时，MQTT 发送失败，且随后的数据库 `UPDATE` 操作因为网络异常引发的流程阻塞或逻辑报错未能成功执行。
* **轮询机制误判**：数据库查询节点（查询 `status='pending'` 的数据）因为状态没能及时更新为 `sent`，在下一个轮询周期（如每 1 秒）又把刚才发送失败的那条数据捞了出来。
* **恶性循环**：数据：捞取 -> 发送失败 -> 状态更新失败 -> 再次捞取，从而形成了死循环，不断消耗 CPU 资源。

---

### 3. 解决方案

引入 **“连接感知”** 与 **“串行确认”** 机制：

#### A. 引入 MQTT 状态监听
使用 `MQTT-In` 或 `Status` 节点实时监听客户端连接状态，并将其存入全局变量（Global/Flow）。

```javascript
// 在状态监听节点中
if (msg.status.text === "connected") {
    flow.set("mqttConnected", true);
} else {
    flow.set("mqttConnected", false);
}
B. 增加查询前的“断路器”
在读取数据库的 Function 节点中增加逻辑判断。如果网络未连接，直接停止查询，不再“取货”。

JavaScript

// --- 逻辑断路器 ---
const isConnected = flow.get("mqttConnected");
if (!isConnected) {
    return null; // 网络断开时，不触发数据库查询
}
C. 优化 SQL 更新语句
同样放弃不稳定的参数绑定，使用字符串拼接确保状态更新指令执行成功。

JavaScript

// 确保精准更新对应 ID 的记录
msg.topic = `UPDATE message_queue SET status='sent' WHERE id = ${msg.payload.id}`;
4. 经验总结 (Lessons Learned)
状态先行：在物联网系统中，任何涉及外部通讯的操作（如发送 MQTT），必须先判断通讯链路状态。

闭环控制：边缘存储转发不能只管“发”，必须建立“发送 -> 确认 -> 更新状态”的闭环逻辑。

流控保护：在异常情况下（如断网），必须有主动熔断机制（Stop Polling），防止系统在无效操作中空转，保护本地计算资源。
