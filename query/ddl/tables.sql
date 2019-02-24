-- Table Definition ----------------------------------------------

CREATE TABLE dictionaries (
    id SERIAL PRIMARY KEY,
    name character varying(32) NOT NULL UNIQUE
);

-- Indices -------------------------------------------------------

CREATE UNIQUE INDEX dictionaries_pkey ON dictionaries(id int4_ops);
CREATE UNIQUE INDEX dictionaries_name_key ON dictionaries(name text_ops);

-- Table Definition ----------------------------------------------

CREATE TABLE words (
    id SERIAL PRIMARY KEY,
    word character varying(128) NOT NULL,
    updated_at timestamp without time zone,
    is_noise boolean,
    dictionary_id integer REFERENCES dictionaries(id) ON DELETE CASCADE
);

-- Indices -------------------------------------------------------

CREATE UNIQUE INDEX words_pkey ON words(id int4_ops);
CREATE UNIQUE INDEX words_dictionary_id_word_idx ON words(dictionary_id int4_ops,word text_ops);
