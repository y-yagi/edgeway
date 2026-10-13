ALTER TABLE todos ADD COLUMN priority TEXT NOT NULL DEFAULT 'normal';
ALTER TABLE todos ADD COLUMN created_at TEXT;
ALTER TABLE todos ADD COLUMN updated_at TEXT;

CREATE TABLE comments (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  todo_id INTEGER NOT NULL REFERENCES todos(id) ON DELETE CASCADE,
  body TEXT NOT NULL,
  created_at TEXT,
  updated_at TEXT
);
CREATE INDEX index_comments_on_todo_id ON comments (todo_id);
