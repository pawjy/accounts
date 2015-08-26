alter table account_link
  add column linked_email VARBINARY(1023) NOT NULL,
  add column linked_data MEDIUMBLOB NOT NULL,
  add KEY (linked_email);
