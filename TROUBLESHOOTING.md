# 🛠️ 故障记录 01：PLC 通讯超时导致的数据库“约束炸弹”

## 故障现场（Symptom）

**现象描述：**
在进行 PLC 采集测试时，若故意切断网络或关闭 Modbus 仿真器，Node-RED 的调试窗口（Debug）会瞬间弹出一连串红色的报错信息：

```
Error: SQLITE_CONSTRAINT: NOT NULL constraint failed: message_queue.topic
```

**后果：**

* 数据库写入完全中断
* 虽然这是由于硬件断开引起的，但软件层面抛出的致命错误导致后续的重连逻辑或报警逻辑受到干扰
* 系统进入一种“半瘫痪”状态

---

## 深度溯源（Root Cause Analysis）

经过对 Node-RED 消息流的逐级抓包分析，我们发现了两个隐藏的致命诱因：

### A. 节点的“空发”机制

Modbus-Read 节点配置了 `Empty msg on fail` 选项。

* 本意：通讯失败时也发个消息，告诉下游“出事了”
* 副作用：它发出的是一个 `payload = ""`（空字符串）的消息
* 由于数据库表结构中 `topic` 字段设置了 `NOT NULL`，这个空 payload 撞上了数据库硬约束，直接引发崩溃

---

### B. 消息对象的“元数据污染”

这是最隐蔽的一点。Node-RED 的消息是一个对象（Object）。

* 现象：即便我们在函数节点里通过 `msg.params = [topic, payload]` 给了值，SQLite 依然报错 NULL
* 原理：数据经过 Modbus 节点后，`msg` 对象里塞满了 buffer、input、寄存器信息等大量工业元数据
* 冲突：当 SQLite 解析 `?` 占位符时，这些深层嵌套数据会干扰驱动程序映射，导致“把有值字段当 NULL 处理”

---

## 解决方案（Final Solution）

我们放弃了传统“参数绑定”写法，改用工业边缘更稳健的 **确定性指令方式**。

---

### 第一步：防御性拦截（清洗）

在进入数据库之前，做一次“安检”。

```javascript
// 在“清洗 & 组装”节点最上方
if (msg.payload === "" || msg.payload == null || msg.error) {
    node.status({fill:"red", shape:"ring", text:"通讯异常，拦截入库"});
    return null;   // 发现空数据或报错，直接斩断流程，保护数据库
}
```

---

### 第二步：指令重构（暴力拼接）

不再让 SQLite 去猜 `msg.params`，而是 **直接写死 SQL**。

```javascript
// 核心改动：直接用模板字符串把变量填进 SQL
const topicStr = msg.topic;
const payloadStr = JSON.stringify(msg.payload);
const now = Date.now();

msg.topic = `
INSERT INTO message_queue (topic, payload, ts, status)
VALUES ('${topicStr}', '${payloadStr}', ${now}, 'pending');
`;

// 关键：彻底清除可能产生干扰的 params 属性
delete msg.params;
```

---

## 经验总结（Lessons Learned）

* 不要相信上游节点：入库前 null 检查是生命线
* 确定性优先于优雅：工业环境下优先保证稳定，而不是“优雅对象映射”
* `msg.params` 在复杂对象链路中极易被污染

---

# 🛠️ 故障记录 02：断网环境下的 MQTT “补发死循环”（Logic Loop）

## 故障现场（Symptom）

**现象描述：**

* 数据堆积：数据库 pending 数据不断增加（符合预期）
* 疯狂重发：断网后系统频繁尝试发送旧数据
* 状态失效：发送后并没有把数据标记为 `sent`

**后果：**

系统陷入：

> 捞取数据 → 发送失败 → 状态更新失败 → 再次捞取相同数据

形成死循环：
不仅恢复网络后云端会收到大量重复数据，还会导致边缘网关负载过高。

---

## 深度溯源（Root Cause Analysis）

### A. “发送”与“标记”的并行陷阱

* MQTT 发送是异步
* 网络异常时发送逻辑阻塞
* 导致另一条 UPDATE SQL 路径没机会执行

---

### B. 轮询机制的“无感知”拉取

* Inject 节点按固定时间触发
* 完全不知道 MQTT 是否连接
* 导致“只进不出旋转门”

---

## 解决方案（Final Solution）

我们引入 **断路器（Circuit Breaker）机制**。

---

### 第一步：实时状态感知（门卫）

监听 MQTT Out 连接状态。

```javascript
// 在“更新连接标记”Function 中
if (msg.status && msg.status.fill === "green") {
    flow.set('mqttConnected', true);
} else {
    flow.set('mqttConnected', false);
}
```

---

### 第二步：逻辑断路（查询前校验）

```javascript
// 在 “② 构建查询” 节点开头
const isConnected = flow.get('mqttConnected');

if (isConnected !== true) {
    node.status({fill:"red", shape:"ring", text:"MQTT断开，暂停补发"});
    return null;
}

node.status({fill:"green", shape:"dot", text:"网络正常，正在同步"});
```

---

### 第三步：串行逻辑（确认后更新）

```javascript
msg.topic = `
UPDATE message_queue
SET status='sent'
WHERE id = ${msg.queueId};
`;
```

---

## 经验总结（Lessons Learned）

* 不要盲目同步：必须具备连接感知
* 断路器设计至关重要
* 存储转发的核心不是“存”，而是“状态转换闭环”

---

# 🛠️ 故障记录 03：数据库运维陷阱（体积膨胀与时区偏差）

## 故障现场（Symptom）

* `.db` 文件体积只增不减
* ts 字段难以阅读（毫秒戳 / 时间偏 8 小时）
* 删除数据后 ID 仍持续递增

---

## 深度溯源（Root Cause Analysis）

### A. SQLite 的“空闲页”机制

* 删除只是标记 free
* 不主动缩文件
* 长期运行磁盘膨胀

### B. Unix 时间戳 vs 北京时间

* `Date.now()` 为 Unix
* `toISOString()` 为 UTC
* 导致中国区 +8 小时偏差

### C. 自增 ID 不回退

* `AUTOINCREMENT` 由 `sqlite_sequence` 管控
* 为防止冲突不会回滚

---

## 解决方案（Final Solution）

### 第一步：入库时间“北京化”

```javascript
const d = new Date();
const beijingDate = new Date(d.getTime() + (8 * 60 * 60 * 1000));
const nowStr = beijingDate.toISOString().replace('T', ' ').substring(0, 19);

msg.topic = `
INSERT INTO message_queue (..., ts, ...)
VALUES (..., '${nowStr}', ...);
`;
```

---

### 第二步：精准定时清理

```sql
DELETE FROM message_queue
WHERE status='sent'
AND ts < datetime('now', '+8 hours', '-7 days');
```

---

### 第三步：强制压缩（VACUUM）

```javascript
msg.topic = "VACUUM;";
return msg;
```

---

## 经验总结（Lessons Learned）

* 工业排错优先“可读时间”
* 仅 DELETE 不够，必须配合 VACUUM
* 真正可长期运行的系统必须包含
  “采集 → 存储 → 转发 → 清理 → 运维”

