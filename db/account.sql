CREATE TABLE IF NOT EXISTS `session` (
  sk BINARY(100) NOT NULL,
  `sk_context` VARBINARY(31),
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
  `user_status` TINYINT UNSIGNED NOT NULL,
  `admin_status` TINYINT UNSIGNED NOT NULL,
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
  linked_key VARBINARY(511) DEFAULT NULL,
  linked_id VARBINARY(511) DEFAULT NULL,
  linked_token1 VARBINARY(1023) NOT NULL,
  linked_token2 VARBINARY(1023) NOT NULL,
  linked_email VARBINARY(1023) NOT NULL,
  linked_data MEDIUMBLOB NOT NULL,
  PRIMARY KEY (account_link_id),
  UNIQUE KEY (account_id, service_name, linked_id),
  UNIQUE KEY (account_id, service_name, linked_key),
  KEY (created),
  KEY (updated),
  KEY (service_name, linked_id),
  KEY (service_name, linked_key),
  KEY (linked_email)
) DEFAULT CHARSET=BINARY ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS account_data (
  account_id BIGINT UNSIGNED NOT NULL,
  `key` VARBINARY(63) NOT NULL,
  `value` MEDIUMBLOB NOT NULL,
  `created` DOUBLE NOT NULL,
  `updated` DOUBLE NOT NULL,
  PRIMARY KEY (`account_id`, `key`),
  KEY (`created`),
  KEY (`updated`)
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

create table if not exists `group` (
  `context_key` VARBINARY(31),
  `group_id` bigint unsigned not null,
  `created` double not null,
  `updated` double not null,
  `owner_status` TINYINT UNSIGNED NOT NULL,
  `admin_status` TINYINT UNSIGNED NOT NULL,
  primary key (`group_id`),
  key (`context_key`, `created`),
  key (`created`),
  key (`updated`)
) default charset=binary engine=innodb;

CREATE TABLE IF NOT EXISTS `group_data` (
  `group_id` BIGINT UNSIGNED NOT NULL,
  `key` VARBINARY(63) NOT NULL,
  `value` MEDIUMBLOB NOT NULL,
  `created` DOUBLE NOT NULL,
  `updated` DOUBLE NOT NULL,
  PRIMARY KEY (`group_id`, `key`),
  KEY (`created`),
  KEY (`updated`)
) DEFAULT CHARSET=BINARY ENGINE=InnoDB;

create table if not exists `group_member` (
  `context_key` VARBINARY(31),
  `group_id` bigint unsigned not null,
  `account_id` bigint unsigned not null,
  `created` double not null,
  `updated` double not null,
  `member_type` tinyint unsigned not null,
  `owner_status` TINYINT UNSIGNED NOT NULL,
  `user_status` TINYINT UNSIGNED NOT NULL,
  primary key (`group_id`, `account_id`),
  key (`account_id`, `updated`),
  key (`created`),
  key (`updated`)
) default charset=binary engine=innodb;

CREATE TABLE IF NOT EXISTS `group_member_data` (
  `group_id` BIGINT UNSIGNED NOT NULL,
  `account_id` bigint unsigned not null,
  `key` VARBINARY(63) NOT NULL,
  `value` MEDIUMBLOB NOT NULL,
  `created` DOUBLE NOT NULL,
  `updated` DOUBLE NOT NULL,
  PRIMARY KEY (`group_id`, `account_id`, `key`),
  key (`group_id`, `key`),
  KEY (`created`),
  KEY (`updated`)
) DEFAULT CHARSET=BINARY ENGINE=InnoDB;

create table if not exists `invitation` (
  `context_key` VARBINARY(31),
  `invitation_context_key` varbinary(511),
  `invitation_key` binary(30),
  `author_account_id` bigint unsigned not null,
  `invitation_data` mediumblob not null,
  `target_account_id` bigint unsigned not null default 0,
  `created` double not null,
  `expires` double not null,
  `user_account_id` bigint unsigned not null default 0,
  `used_data` mediumblob not null,
  `used` double not null,
  primary key (`context_key`, `invitation_context_key`, `invitation_key`),
  key (`invitation_context_key`, `invitation_key`),
  key (`invitation_context_key`, `author_account_id`, `created`),
  key (`invitation_context_key`, `target_account_id`, `created`),
  key (`invitation_context_key`, `user_account_id`, `used`),
  key (`created`),
  key (`expires`),
  key (`used`)
) default charset=binary engine=innodb;

create table if not exists `icon` (
  `context_key` VARBINARY(63),
  `target_type` tinyint unsigned not null,
  `target_id` bigint unsigned not null,
  `created` double not null,
  `updated` double not null,
  `admin_status` TINYINT UNSIGNED NOT NULL,
  `url` varbinary(1023) not null,
  primary key (`context_key`, `target_type`, `target_id`),
  key (`target_type`, `target_id`),
  key (`context_key`, `created`),
  key (`url`),
  key (`created`),
  key (`updated`)
) default charset=binary engine=innodb;
