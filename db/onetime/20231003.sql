
CREATE TABLE IF NOT EXISTS `session_recent_log` (
  sk BINARY(100) NOT NULL,
  `sk_context` VARBINARY(31),
  `session_id` BIGINT UNSIGNED NOT NULL,
  `account_id` BIGINT UNSIGNED NOT NULL,
  `timestamp` DOUBLE NOT NULL,
  `expires` DOUBLE NOT NULL,
  `data` MEDIUMBLOB NOT NULL,
  PRIMARY KEY (sk),
  UNIQUE KEY (`session_id`),
  KEY (`account_id`, `timestamp`),
  KEY (`timestamp`),
  KEY (expires)
) DEFAULT CHARSET=BINARY ENGINE=InnoDB;
