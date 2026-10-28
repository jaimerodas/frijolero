-- A link that changes the email of its user: it goes to new_email, so a click on it
-- proves that the person reads that inbox. NULL is a plain sign-in link.

ALTER TABLE signin_tokens ADD COLUMN new_email TEXT;
