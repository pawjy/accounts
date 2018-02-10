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
