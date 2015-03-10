create table if not exists `session` (
  session_id VARBINARY(255) NOT NULL,
  created DOUBLE NOT NULL,
  `data` MEDIUMBLOB NOT NULL,
  PRIMARY KEY (session_id),
  KEY (created)
) default charset=binary engine=innodb;
