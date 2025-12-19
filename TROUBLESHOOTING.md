# 🛠️ 边缘转发系统故障记录 (Troubleshooting Log)

本项目记录了在开发 Node-RED 边缘存储转发框架过程中遇到的核心问题及解决方案。

---

## 🛠️ 故障记录 01：PLC 通讯超时导致的数据库“约束炸弹”

1. 故障现场（Symptom）

现象描述： 在进行 PLC 采集测试时，若故意切断网络或关闭 Modbus 仿真器，Node-RED 的调试窗口（Debug）会瞬间弹出一连串红色的报错信息：

Error: SQLITE_CONSTRAINT: NOT NULL constraint failed: message_queue.topic

后果：

- 数据库写入完全中断。
- 虽然这是由于硬件断开引起的，但软件层面抛出的致命错误导致后续的重连逻辑或报警逻辑受到干扰，系统进入一种“半瘫痪”状态。

2. 深度溯源（Root Cause Analysis）

经过对 Node-RED 消息流的逐级抓包分析，我们发现了两个隐藏的致命诱因：

A. 节点的“空发”机制  
Modbus-Read 节点配置了 `Empty msg on fail` 选项。  
本意：通讯失败时也发个消息，告诉下游“出事了”。  
副作用：它发出的是一个 payload 为 `""`（空字符串）的消息。由于我们的数据库表结构中 `topic` 字段设置了 `NOT NULL`（不允许为空），这个空 payload 撞上了数据库的硬约束，直接引发崩溃。

B. 消息对象的“元数据污染”  
这是最隐蔽的一点。Node-RED 的消息是一个对象（Object）。  
现象：即便我们在函数节点里通过 `msg.params = [topic, payload]` 给了值，SQLite 节点依然报错说收到了 `NULL`。  
原理：数据经过 Modbus 节点后，`msg` 对象里塞满了 `buffer`（原始字节）、`input`（寄存器信息）等大量工业元数据。  
冲突：当下游 SQLite 节点尝试解析 `?` 占位符时，这些深层嵌套的臃肿数据干扰了驱动程序的判断，导致它在映射参数时“迷路”了，最终把原本有值的字段按 `NULL` 处理。

3. 解决方案（Final Solution）

我们放弃了传统的“参数绑定”写法，改用了工业边缘侧更稳健的 “确定性指令” 方案。总体思路分两步：先做防御性拦截，随后用确定性更高的 SQL 指令直接下发。

第一步：防御性拦截（清洗）  
在进入数据库之前，先做一次“安检”，确保坏数据不会污染数据库。

```javascript
// 在“清洗 & 组装”节点最上方
if (msg.payload === "" || msg.payload == null || msg.error) {
    node.status({fill:"red", shape:"ring", text:"通讯异常，拦截入库"});
    return null; // 发现空数据或报错，直接斩断流程，保护数据库
}
```

第二步：指令重构（暴力拼接）  
不再让 SQLite 节点去猜 `msg.params` 里的内容，而是直接把命令写死在 `msg.topic` 里，确保驱动只执行我们明确给出的 SQL。

```javascript
// 核心改动：直接用模板字符串把变量填进 SQL
const topicStr = (typeof msg.topic === 'string') ? msg.topic.replace(/'/g, "''") : String(msg.topic);
const payloadStr = JSON.stringify(msg.payload).replace(/'/g, "''");
const now = Date.now();

msg.topic = `INSERT INTO message_queue (topic, payload, ts, status) 
             VALUES ('${topicStr}', '${payloadStr}', ${now}, 'pending')`;

// 关键：彻底清除可能产生干扰的 params 属性
if (msg.params) delete msg.params;
```

（注：示例中做了简单的单引号转义以降低 SQL 注入风险；在生产环境应结合字段格式、长度限制与白名单校验进一步加强。）

4. 经验总结（Lessons Learned）

- 不要相信上游节点：在处理 PLC/传感器数据时，必须假设数据随时会断、会乱，入库前的 null/空字符串检查是生命线。  
- 确定性高于优雅：在复杂的 Node-RED 流程中，`msg.params` 这种“对象映射”方式虽然优雅，但容易被元数据污染。直接拼接 SQL 字符串看起来“暴力”，但在工业环境下提供了更高的确定性与稳定性（注意用简单的转义和校验来降低风险）。  
- 防御优先：对所有外部来源的数据都应进行“先验证、后处理”的策略，尽量在边缘侧用最小改动保护后端数据库的完整性与可用性。

---
