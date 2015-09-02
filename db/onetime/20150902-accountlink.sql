alter table account_link
  modify linked_key VARBINARY(511) DEFAULT NULL,
  modify linked_id VARBINARY(511) DEFAULT NULL;
