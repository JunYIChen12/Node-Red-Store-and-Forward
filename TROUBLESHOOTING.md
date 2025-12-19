🛠️ 故障记录 01：PLC 通讯超时导致的数据库“约束炸弹”
1. 故障现场（Symptom）
现象描述： 在进行 PLC 采集测试时，若故意切断网络或关闭 Modbus 仿真器，Node-RED 的调试窗口（Debug）会瞬间弹出一连串红色的报错信息： Error: SQLITE_CONSTRAINT: NOT NULL constraint failed: message_queue.topic

后果：

数据库写入完全中断。

虽然这是由于硬件断开引起的，但软件层面抛出的致命错误导致后续的重连逻辑或报警逻辑受到干扰，系统进入一种“半瘫痪”状态。

2. 深度溯源（Root Cause Analysis）
经过对 Node-RED 消息流的逐级抓包分析，我们发现了两个隐藏的致命诱因：

A. 节点的“空发”机制
Modbus-Read 节点配置了 Empty msg on fail 选项。

本意：通讯失败时也发个消息，告诉下游“出事了”。

副作用：它发出的是一个 payload 为 ""（空字符串）的消息。由于我们的数据库表结构中 topic 字段设置了 NOT NULL（不允许为空），这个空 payload 撞上了数据库的硬约束，直接引发崩溃。

B. 消息对象的“元数据污染”
这是最隐蔽的一点。Node-RED 的消息是一个对象（Object）。

现象：即便我们在函数节点里通过 msg.params = [topic, payload] 给了值，SQLite 节点依然报错说收到了 NULL。

原理：数据经过 Modbus 节点后，msg 对象里塞满了 buffer（原始字节）、input（寄存器信息）等大量工业元数据。

冲突：当下游 SQLite 节点尝试解析 ? 占位符时，这些深层嵌套的臃肿数据干扰了驱动程序的判断，导致它在映射参数时“迷路”了，最终把原本有值的字段按 NULL 处理。

3. 解决方案（Final Solution）
我们放弃了传统的“参数绑定”写法，改用了工业边缘侧更稳健的 “确定性指令” 方案。

第一步：防御性拦截（清洗）
在进入数据库之前，先做一次“安检”，确保坏数据不会污染数据库。

JavaScript

// 在“清洗 & 组装”节点最上方
if (msg.payload === "" || msg.payload == null || msg.error) {
    node.status({fill:"red", shape:"ring", text:"通讯异常，拦截入库"});
    return null; // 发现空数据或报错，直接斩断流程，保护数据库
}
第二步：指令重构（暴力拼接）
不再让 SQLite 节点去猜 msg.params 里的内容，而是直接把命令写死在 msg.topic 里。

JavaScript

// 核心改动：直接用模板字符串把变量填进 SQL
const topicStr = msg.topic;
const payloadStr = JSON.stringify(msg.payload);
const now = Date.now();

msg.topic = `INSERT INTO message_queue (topic, payload, ts, status) 
             VALUES ('${topicStr}', '${payloadStr}', ${now}, 'pending')`;

// 关键：彻底清除可能产生干扰的 params 属性
delete msg.params; 
4. 经验总结（Lessons Learned）
不要相信上游节点：在处理 PLC/传感器数据时，必须假设数据随时会断、会乱，入库前的 null 检查是生命线。

确定性高于优雅：在复杂的 Node-RED 流程中，msg.params 这种“对象映射”方式很优雅，但容易被元数据污染。直接拼接 SQL 字符串虽然看起来“暴力”，但它在工业环境下具有最高的确定性和稳定性。

🛠️ 故障记录 02：断网环境下的 MQTT “补发死循环” (Logic Loop)
1. 故障现场（Symptom）
现象描述： 在模拟断网测试（手动关闭 MQTT Broker 或拔掉网线）时，观察到以下异常行为：

数据堆积：数据库中的 pending 数据不断增加，这是符合预期的。

疯狂重发：一旦网络断开，MQTTX 客户端或 Debug 窗口会监控到系统在以极高的频率尝试发送完全相同的旧数据。

状态失效：原本设定好的“发送后将状态改为 sent”逻辑似乎完全没有生效，数据库里的那条数据始终是 pending 状态。

后果： 系统陷入了“捞取数据 -> 发送失败 -> 状态更新失败 -> 再次捞取相同数据”的死循环。这不仅导致恢复连接后云端收到大量重复数据，还会导致边缘网关负载过高。

2. 深度溯源（Root Cause Analysis）
通过追踪消息流在断网瞬间的走向，我们发现了两个逻辑设计的缺陷：

A. “发送”与“标记”的并行陷阱
原本的 Node-RED 连线方式是并行的：一条线连 MQTT 发送，另一条线连 SQL 更新。

物理事实：MQTT 发送是一个异步过程。当网络断开时，MQTT 节点会报错并阻塞或重连。

逻辑后果：由于网络异常，消息流可能在发送端就卡住了，导致另一条支路上的 UPDATE 语句（标记已发送）根本没有机会执行，或者因为消息对象的上下文丢失而执行失败。

B. 轮询机制的“无感知”拉取
我们的轮询触发器（Inject 节点）是按固定时间（如 5 秒）盲目触发的。

盲目性：轮询节点只管去数据库捞 status='pending' 的数据，它并不知道当前的 MQTT 连接是否健康。

结果：旧数据还没发出去（没变状态），新一轮轮询又把它捞了出来。这就形成了一个只进不出的“旋转门”。

3. 解决方案（Final Solution）
我们引入了 “断路器（Circuit Breaker）” 机制，确保系统在异常时主动“罢工”。

第一步：实时状态感知（门卫）
利用 Node-RED 的 Status 节点监听 MQTT Out 节点的底层连接颜色（绿色代表连接，红色/黄色代表异常）。

JavaScript

// 在“更新连接标记”Function 节点中
if (msg.status && msg.status.fill === "green") {
    flow.set('mqttConnected', true); // 设置全局通行证
} else {
    flow.set('mqttConnected', false); // 吊销通行证
}
第二步：逻辑断路（查询前校验）
在执行 SQL 查询（加载 Pending 数据）之前，增加一道严格的审查逻辑。

JavaScript

// 在“② 构建查询”节点开头
const isConnected = flow.get('mqttConnected');

if (isConnected !== true) {
    // 如果没连上云端，直接 null 掉消息，不触发数据库查询
    node.status({fill:"red", shape:"ring", text:"MQTT断开，暂停补发"});
    return null; 
}

node.status({fill:"green", shape:"dot", text:"网络正常，正在同步"});
// ...后续执行 SELECT 语句
第三步：串行逻辑（确认后更新）
虽然目前的方案通过“断路器”解决了大部分问题，但更稳健的做法是确保 UPDATE 语句使用拼接好的 ID 进行精准操作。

JavaScript

// 确保使用解析出的 queueId 进行更新，防止误伤
msg.topic = `UPDATE message_queue SET status='sent' WHERE id = ${msg.queueId}`;
4. 经验总结（Lessons Learned）
不要“盲目”同步：在边缘计算中，本地数据库到远程云端的数据同步必须具备连接感知能力。

断路器设计模式：当外部资源（如云端服务器）不可用时，程序应当主动切断相关的资源消耗逻辑，进入“保护模式”。

状态闭环：存储转发系统的核心不在于“存”，而在于“状态转换”的严密性。只有确认链路可用，数据才应该被从仓库（数据库）中提取出来。

🛠️ 故障记录 03：数据库运维陷阱（体积膨胀与时区偏差）
1. 故障现场（Symptom）
现象描述：

磁盘占用异常：即便配置了定期删除 7 天前数据的脚本，.db 文件的体积依然只增不减，长期运行可能导致边缘网关磁盘溢出。

数据排查困难：数据库中存储的时间（ts 字段）是一串类似 1766126247660 的数字（毫秒戳），或者比实际时间晚了 8 小时。在 DataGrip 或 MQTTX 监控数据时，无法直观判断数据产生的具体时刻。

ID 持续跳变：删除旧数据后，新插入的数据 ID 依然从上千开始叠加，没有回到 1。

2. 深度溯源（Root Cause Analysis）
A. SQLite 的“空闲页”机制
SQLite 删除数据时，并不会立刻缩减文件大小。

原理：它只是将存放数据的磁盘空间标记为“Free（空闲）”。它预想你以后还会存新数据，所以先占着坑不还给系统。

后果：如果系统中产生的临时数据极多，文件会一直维持在历史最高点的体积。

B. Unix 时间戳与 UTC 偏移
默认值：Node-RED 中的 Date.now() 输出的是 Unix 时间戳。

时区差异：toISOString() 函数默认输出的是 UTC（格林威治）时间，而中国处于东八区（UTC+8）。如果不手动转换，数据库里的时间永远对不上。

C. 自增 ID 的防重机制
SQLite 的 AUTOINCREMENT 记录在 sqlite_sequence 表中。它为了保证数据 ID 的唯一性（防止旧日志引用冲突），默认不会在删除后重置 ID。

3. 解决方案（Final Solution）
我们通过重写清洗逻辑和增加自动维护任务，实现了“北京时间对齐”与“磁盘自动压缩”。

第一步：入库时间“北京化”
在数据进入数据库之前，手动修正时区偏移，并将时间存为更具可读性的字符串。

JavaScript

// 在“① 清洗 & 组装”节点中
const d = new Date();
// 手动加上 8 小时的毫秒数
const beijingDate = new Date(d.getTime() + (8 * 60 * 60 * 1000));
// 格式化为: 2025-12-19 14:30:00
const nowStr = beijingDate.toISOString().replace('T', ' ').substring(0, 19);

// 存入 SQL
msg.topic = `INSERT INTO message_queue (..., ts, ...) VALUES (..., '${nowStr}', ...)`;
第二步：精准定时清理（北京时间基准）
利用 SQLite 内置函数，配合修正后的时区进行滚动清理。

SQL

-- 在清理节点中执行
DELETE FROM message_queue 
WHERE status='sent' 
AND ts < datetime('now', '+8 hours', '-7 days');
第三步：强制“锯书架”（磁盘压缩）
在清理数据后，紧接着发送 VACUUM; 命令。

作用：强制 SQLite 重新整理文件，并将空闲空间归还给操作系统。

JavaScript

// 清理节点后的 Function
msg.topic = "VACUUM;";
return msg;
4. 经验总结（Lessons Learned）
机器语言 vs 人类语言：虽然 Unix 时间戳利于计算，但在工业排错场景下，格式化的北京时间字符串能节省大量的沟通和排错成本。

不仅仅是 DELETE：在 SQLite 运维中，删除数据只是第一步，必须配合 VACUUM 才能真正解决磁盘空间问题。

系统闭环：一个成熟的边缘存储系统必须包含“采集、存储、转发、清理、维护”五个环节，缺少最后两个环节的系统是不具备工业长期运行能力的。
