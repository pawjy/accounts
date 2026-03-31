
DROP TABLE IF EXISTS `login_token`;
CREATE TABLE `login_token` (
  `email_sha` BINARY(40) NOT NULL,
  `token` VARBINARY(8) NOT NULL,
  `expires` DOUBLE NOT NULL,
  `attempts` TINYINT UNSIGNED NOT NULL DEFAULT 0,
  `created` DOUBLE NOT NULL,
  `ipaddr` VARBINARY(127) NOT NULL,
  `status` TINYINT UNSIGNED NOT NULL DEFAULT 1,
  PRIMARY KEY (`email_sha`, `created`),
  KEY (`expires`),
  KEY (`created`),
  KEY (`ipaddr`, `created`)
) DEFAULT CHARSET=BINARY ENGINE=InnoDB;
