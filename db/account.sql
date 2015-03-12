CREATE TABLE IF NOT EXISTS `session` (
  sk BINARY(100) NOT NULL,
  sk_context VARBINARY(15),
  created DOUBLE NOT NULL,
  expires DOUBLE NOT NULL,
  `data` MEDIUMBLOB NOT NULL,
  PRIMARY KEY (sk),
  KEY (created),
  KEY (expires)
) DEFAULT CHARSET=BINARY ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS `account` (
  account_id BIGINT UNSIGNED NOT NULL,
  created DOUBLE NOT NULL,
  user_status TINYINT UNSIGNED NOT NULL,
  admin_status TINYINT UNSIGNED NOT NULL,
  terms_version TINYINT UNSIGNED NOT NULL,
  `name` VARBINARY(1023) NOT NULL,
  PRIMARY KEY (account_id),
  KEY (created)
) DEFAULT CHARSET=BINARY ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS `account_link` (
  account_link_id BIGINT UNSIGNED NOT NULL,
  account_id BIGINT UNSIGNED NOT NULL,
  service_name VARBINARY(31) NOT NULL,
  created DOUBLE NOT NULL,
  updated DOUBLE NOT NULL,
  linked_name VARBINARY(1023) NOT NULL,
  linked_id VARBINARY(512) NOT NULL,
  linked_token1 VARBINARY(1023) NOT NULL,
  linked_token2 VARBINARY(1023) NOT NULL,
  PRIMARY KEY (account_link_id),
  UNIQUE KEY (account_id, service_name, linked_id),
  KEY (created),
  KEY (updated),
  KEY (service_name, linked_id)
) DEFAULT CHARSET=BINARY ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS account_log (
  log_id BIGINT UNSIGNED NOT NULL,
  account_id BIGINT UNSIGNED NOT NULL,
  operator_account_id BIGINT UNSIGNED NOT NULL,
  `timestamp` DOUBLE NOT NULL,
  `action` VARBINARY(63) NOT NULL,
  ua VARBINARY(1023) NOT NULL,
  ipaddr VARBINARY(127) NOT NULL,
  `data` MEDIUMBLOB NOT NULL,
  PRIMARY KEY (log_id),
  KEY (action, timestamp),
  KEY (account_id, action, timestamp),
  KEY (operator_account_id, timestamp),
  KEY (ipaddr, timestamp),
  KEY (timestamp)
) DEFAULT CHARSET=BINARY ENGINE=InnoDB;
