alter table account_link
  add column linked_email VARBINARY(1023) NOT NULL,
  add column linked_data MEDIUMBLOB NOT NULL,
  add KEY (linked_email);

CREATE TABLE IF NOT EXISTS account_data (
  account_id BIGINT UNSIGNED NOT NULL,
  `key` VARBINARY(63) NOT NULL,
  `value` MEDIUMBLOB NOT NULL,
  created DOUBLE NOT NULL,
  updated DOUBLE NOT NULL,
  PRIMARY KEY (`account_id`, `key`),
  KEY (created),
  KEY (updated)
) DEFAULT CHARSET=BINARY ENGINE=InnoDB;
