# Node-RED SQLite 存储转发（精简版）

面向内存受限的边缘网关，使用 Node-RED + SQLite + MQTT 实现的轻量级存储转发流程。通过 SQLite 将接收到的 PLC 数据落盘，网络恢复后按顺序重发，确保数据不丢失。

## 文件说明
- `flows_store_forward.json`：可直接导入 Node-RED 的流程，包含 MQTT 接收、SQLite 入库、周期出队转发、发送后更新状态的全链路节点。
- `sqlite-init.sql`：SQLite 初始化脚本，创建 `message_queue` 表及状态索引。

## 流程概览（精简）
1. **MQTT 接收 → 入库**：`mqtt-in → Normalize & buffer → sqlite` 将消息以 `pending` 状态写入 SQLite。
2. **周期出队 → 转发**：`inject → Query batch → sqlite → split → To MQTT → mqtt-out` 逐条发布，发布后 `Mark sent → sqlite` 将状态改为 `sent`。
3. **错误捕获**：`catch → debug` 输出到调试面板，方便定位异常。

## 环境变量（可选）
- `MQTT_HOST` / `MQTT_PORT`：MQTT 服务器地址与端口，默认 `localhost:1883`。
- `MQTT_IN_TOPIC`：订阅主题，默认 `plc/data`。
- `DB_PATH`：SQLite 文件路径，默认 `/data/store-and-forward.db`。
- `RETRY_SECONDS`：轮询待发送的周期，默认 5 秒。
- `BATCH_LIMIT`：每轮读取的最大待发送条数，默认 10（控制内存占用）。

## 使用步骤
1. 在目标设备安装 Node-RED，并通过 Palette 安装 `node-red-node-sqlite` 节点。
2. 创建数据库文件并执行 `sqlite-init.sql`（或让 Node-RED 第一次写入时自动创建文件）。
3. 打开 Node-RED 编辑器，导入 `flows_store_forward.json`。在 MQTT Broker 节点中填入实际服务器地址、凭据及 QoS=1。
4. 部署后，流程会自动开始轮询 `pending` 数据并转发成功后标记 `sent`，断网恢复后会按顺序补发。

## Windows 环境运行指引
> 适用于资源受限的网关或工控 PC，遵循默认的低内存批处理策略即可。

1. **安装 Node.js LTS**：从 <https://nodejs.org/> 下载 Windows x64 LTS 版本并安装（包含 npm）。
2. **安装 Node-RED**：在命令行运行 `npm install -g --unsafe-perm node-red`。完成后可在终端执行 `node-red` 启动服务。
3. **安装 SQLite 节点**：在 Node-RED Palette 中搜索并安装 `node-red-node-sqlite`。Windows 自带 SQLite DLL，无需额外编译。
4. **初始化数据库**：
   - 打开命令提示符，进入本仓库目录（或你希望存放数据库的路径）。
   - 运行 `sqlite3 store-and-forward.db < sqlite-init.sql` 创建表结构；或将 `DB_PATH` 指向文件路径，让流程首次写入时自动创建。
5. **导入流程**：在浏览器打开 <http://127.0.0.1:1880>，使用右上角菜单“导入”粘贴 `flows_store_forward.json` 内容。
6. **配置 MQTT**：双击流程中的 MQTT 节点，填入你的 Broker 地址、端口、用户名/密码，确保 QoS=1，并匹配订阅/发布的主题。
7. **运行与验证**：部署后，观察 Debug 面板，确认收到的消息落盘到 SQLite，并在网络恢复时按批次发送。若需调整资源占用，可在环境变量或全局配置里修改 `BATCH_LIMIT`、`RETRY_SECONDS`。

### 常见问题（Windows）
- 如果启动时提示端口 1880 被占用，可在命令行设置 `set PORT=1881` 后再运行 `node-red`。
- 若 `node-red-node-sqlite` 安装失败，确保 npm 拥有写入权限；可尝试以管理员权限重新运行命令行。

## 资源友好性
- 仅使用核心节点 + SQLite，查询按 `BATCH_LIMIT` 分批、`split` 逐条发送，降低内存压力。
- 数据按 QoS 1 存储，发送成功后更新状态，不额外缓存。
