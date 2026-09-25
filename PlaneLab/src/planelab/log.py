"""Logging for Plane Lab (SPEC.md §17.4 P8): a rotating log file created silently, plus warnings on stderr for the CLI.

Inside Blender, operators also report through ``self.report``; that stays in the Blender glue.
"""

import logging
import os
from logging.handlers import RotatingFileHandler
from pathlib import Path

LOGGER_NAME = "planelab"
_FORMAT = "%(asctime)s %(levelname)s %(name)s: %(message)s"


def log_directory() -> Path:
    """``$PLANELAB_LOG_DIR`` when set (tests use it), otherwise ``~/PlaneLab/logs``."""
    override = os.environ.get("PLANELAB_LOG_DIR")
    return Path(override) if override else Path.home() / "PlaneLab" / "logs"


def setup_logging(*, console: bool = False, level: int = logging.INFO) -> logging.Logger:
    """Attaches the file handler (once) and, with ``console``, a stderr handler for warnings and errors."""
    logger = logging.getLogger(LOGGER_NAME)
    logger.setLevel(level)
    if not any(isinstance(h, RotatingFileHandler) for h in logger.handlers):
        try:
            directory = log_directory()
            directory.mkdir(parents=True, exist_ok=True)
            file_handler = RotatingFileHandler(
                directory / "planelab.log", maxBytes=5_000_000, backupCount=3, encoding="utf-8"
            )
        except OSError as error:
            # An unwritable home must not stop the lab; say so once on stderr and carry on without a file.
            logging.getLogger(__name__).warning("no log file: %s", error)
        else:
            file_handler.setFormatter(logging.Formatter(_FORMAT))
            logger.addHandler(file_handler)
    if console and not any(type(h) is logging.StreamHandler for h in logger.handlers):
        stream = logging.StreamHandler()
        stream.setLevel(logging.WARNING)
        stream.setFormatter(logging.Formatter("planelab: %(levelname)s: %(message)s"))
        logger.addHandler(stream)
    return logger
