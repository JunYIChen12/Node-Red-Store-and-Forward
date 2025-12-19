CREATE TABLE IF NOT EXISTS message_queue (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  topic TEXT NOT NULL,
  payload TEXT NOT NULL,
  qos INTEGER DEFAULT 1,
  ts INTEGER NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending',
  retries INTEGER DEFAULT 0,
  sent_at INTEGER
);

CREATE INDEX IF NOT EXISTS idx_message_queue_status ON message_queue (status, id);
