
alter table `account_link`
  modify linked_token1 VARBINARY(1023) NOT NULL,
  modify linked_token2 VARBINARY(1023) NOT NULL;
