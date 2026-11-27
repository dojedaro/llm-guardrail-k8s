"""One JSON object per log line on stdout. Callers pass fields via `extra`;
never pass message content, only metadata (decision, rule ids, latency)."""

from __future__ import annotations

import json
import logging
import sys
from datetime import UTC, datetime

_STD = set(logging.makeLogRecord({}).__dict__) | {"message", "asctime"}


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        doc = {
            "ts": datetime.fromtimestamp(record.created, UTC).isoformat(),
            "level": record.levelname,
            "msg": record.getMessage(),
        }
        doc.update({k: v for k, v in record.__dict__.items() if k not in _STD})
        if record.exc_info:
            doc["exc"] = self.formatException(record.exc_info)
        return json.dumps(doc, default=str)


def setup_logging(level: str = "INFO") -> logging.Logger:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())
    log = logging.getLogger("gateway")
    log.handlers[:] = [handler]
    log.setLevel(level.upper())
    log.propagate = False
    return log
