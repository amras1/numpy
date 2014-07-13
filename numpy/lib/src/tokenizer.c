// Licensed under a 3-clause BSD style license - see LICENSE.rst

#include "tokenizer.h"

tokenizer_t *create_tokenizer(uint32_t delimiter, uint32_t comment, uint32_t quotechar,
                              int fill_extra_cols, int strip_whitespace_lines,
                              int strip_whitespace_fields)
{
    // Create the tokenizer in memory
    tokenizer_t *tokenizer = (tokenizer_t *) malloc(sizeof(tokenizer_t));

    // Initialize the tokenizer fields
    tokenizer->source = 0;
    tokenizer->source_len = 0;
    tokenizer->source_pos = 0;
    tokenizer->delimiter = delimiter;
    tokenizer->comment = comment;
    tokenizer->quotechar = quotechar;
    tokenizer->header_output = 0;
    tokenizer->output_cols = 0;
    tokenizer->col_ptrs = 0;
    tokenizer->header_len = 0;
    tokenizer->output_len = 0;
    tokenizer->num_cols = 0;
    tokenizer->num_rows = 0;
    tokenizer->fill_extra_cols = fill_extra_cols;
    tokenizer->state = START_LINE;
    tokenizer->code = NO_ERROR;
    tokenizer->iter_col = 0;
    tokenizer->curr_pos = 0;
    tokenizer->strip_whitespace_lines = strip_whitespace_lines;
    tokenizer->strip_whitespace_fields = strip_whitespace_fields;

    // This is a bit of a hack -- buf holds an empty string to represent
    // empty field values
    tokenizer->buf = calloc(2, sizeof(char));

    return tokenizer;
}

void delete_data(tokenizer_t *tokenizer)
{
    // Don't free tokenizer->source because it points to part of
    // an already freed Python object
    free(tokenizer->header_output);
    int i;

    if (tokenizer->output_cols)
	for (i = 0; i < tokenizer->num_cols; ++i)
	    free(tokenizer->output_cols[i]);
    
    free(tokenizer->output_cols);
    free(tokenizer->col_ptrs);

    // Set pointers to 0 so we don't use freed memory when reading over again
    tokenizer->header_output = 0;
    tokenizer->output_cols = 0;
    tokenizer->col_ptrs = 0;
}

void delete_tokenizer(tokenizer_t *tokenizer)
{
    delete_data(tokenizer);
    free(tokenizer->buf);
    free(tokenizer);
}

void resize_col(tokenizer_t *self, int index)
{
    // Temporarily store the position in output_cols[index] to
    // which col_ptrs[index] points
    int diff = self->col_ptrs[index] - self->output_cols[index];

    // Double the size of the column string
    self->output_cols[index] = (char *) realloc(self->output_cols[index], 2 * 
                                                self->output_len[index]);

    // Set the second (newly allocated) half of the column string to all zeros
    memset(self->output_cols[index] + self->output_len[index], 0,
           self->output_len[index]);

    self->output_len[index] *= 2;
    // realloc() might move the address in memory, so we have to move
    // col_ptrs[index] to an offset of the new address
    self->col_ptrs[index] = self->output_cols[index] + diff;
}

void resize_header(tokenizer_t *self)
{
    // Double the size of the header string
    self->header_output = (char *) realloc(self->header_output, 2 *
                                           self->header_len);

    // Set the second half of the header string to all zeros
    memset(self->header_output + self->header_len, 0,
           self->header_len);
    self->header_len *= 2;
}

/*
  If we are tokenizing the header, resize the header string if necessary 
  and then set the char at the current output position to c, incrementing
  the current position afterwards.

  If we are tokenizing data but we have too many columns or use_cols[real_col]
  is 0 (meaning that this column should be excluded from output), do nothing.
  Otherwise, resize the column string if necessary and then append c to the
  end of the column string, incrementing the column position pointer.
*/

#define PUSH_C(c, len)                                                  \
    if (header)								\
    {									\
        if (output_pos + self->last_len - 1 >= self->header_len)        \
        {								\
	    resize_header(self);					\
	}								\
        for (j = 0; j < len; ++j)                                       \
            self->header_output[output_pos++] = c;                      \
    }									\
    else if (col < self->num_cols && use_cols[real_col])		\
    {									\
	if (self->col_ptrs[col] - self->output_cols[col] + self->last_len - 1 \
                  >= self->output_len[col])                             \
	{								\
	    resize_col(self, col);					\
	}								\
        for (j = 0; j < len; ++j)                                       \
            *self->col_ptrs[col]++ = c;                                 \
    }

#define PUSH() PUSH_C(self->source_pos[j], self->last_len)
#define PUSH_CHAR(c) PUSH_C(c, 1)

/* Set the state to START_FIELD and begin with the assumption that
   the field is entirely whitespace in order to handle the possibility
   that the comment character is found before any non-whitespace even
   if whitespace stripping is disable.
*/

#define BEGIN_FIELD()                           \
    self->state = START_FIELD;                  \
    whitespace = 1;

/*
  First, backtrack to eliminate trailing whitespace if strip_whitespace_fields
  is true. If the field is empty, push '\x01' as a marker.
  Unless this column will be excluded from output, append a null
  byte to the end of the column string as a field delimiting marker.
  Increment the variable col and eturn the value TOO_MANY_COLS if
  there are too many columns in this row. Increment real_col even if
  this column should be ignored.
*/

#define END_FIELD()							\
    if (header)                                                         \
    {                                                                   \
        if (self->strip_whitespace_fields)                              \
        {                                                               \
            --output_pos;                                               \
            while (self->header_output[output_pos] == ' ' ||            \
                   self->header_output[output_pos] == '\t')             \
            {                                                           \
                self->header_output[output_pos--] = '\x00';             \
            }                                                           \
            ++output_pos;                                               \
        }                                                               \
        if (output_pos == 0 || self->header_output[output_pos - 1] == '\x00') \
        {                                                               \
            PUSH_CHAR('\x01');                                          \
        }                                                               \
        PUSH_CHAR('\x00');                                              \
    }                                                                   \
    else if (real_col >= use_cols_len)                                  \
    {                                                                   \
        RETURN(TOO_MANY_COLS);                                          \
    }                                                                   \
    else if (use_cols[real_col])                                        \
    {                                                                   \
        if (self->strip_whitespace_fields)                              \
        {                                                               \
            --self->col_ptrs[col];                                      \
            while (*self->col_ptrs[col] == ' ' ||                       \
                   *self->col_ptrs[col] == '\t')                        \
            {                                                           \
                *self->col_ptrs[col]-- = '\x00';                        \
            }                                                           \
            ++self->col_ptrs[col];                                      \
        }                                                               \
        if (self->col_ptrs[col] == self->output_cols[col] ||            \
            self->col_ptrs[col][-1] == '\x00')                          \
        {                                                               \
            PUSH_CHAR('\x01');                                          \
        }                                                               \
        PUSH_CHAR('\x00');                                              \
        if (++col > self->num_cols)                                     \
            RETURN(TOO_MANY_COLS);                                      \
    }                                                                   \
    ++real_col;

/*
  If we are tokenizing the header, end after the first line.
  Handle the possibility of insufficient columns appropriately;
  if fill_extra_cols=1, then append empty fields, but otherwise
  return an error. Increment our row count and possibly end if
  all the necessary rows have already been parsed.
*/

#define END_LINE()					\
    if (header)						\
	done = 1;					\
    else if (self->fill_extra_cols)			\
	while (col < self->num_cols)			\
	{						\
            PUSH_CHAR('\x01');				\
	    END_FIELD();				\
	}						\
    else if (col < self->num_cols)			\
	RETURN(NOT_ENOUGH_COLS);			\
    ++self->num_rows;

// Set the error code to c for later retrieval and return c
#define RETURN(c) do { self->code = c; return c; } while (0)

#define CHAR(c) (c & 0xFF)

int tokenize(tokenizer_t *self, int header, int *use_cols, int use_cols_len,
             int skip_rows)
{
    delete_data(self); // clear old reading data
    uint32_t c; // input code point
    int col = 0; // current column ignoring possibly excluded columns
    int real_col = 0; // current column taking excluded columns into account
    int output_pos = 0; // current position in header output string
    self->header_len = INITIAL_HEADER_SIZE;
    self->num_rows = 0;
    self->source_pos = self->source;
    int i = 0;
    int whitespace = 1;
    int j;
    
    while (i < skip_rows)
    {
	if (self->source_pos - self->source >= self->source_len - 1) // ignore final newline
        {
            if (header)
                RETURN(INVALID_LINE); // header line is required
            else
                return NO_ERROR; // no data in input
        }

        c = next_char(self);
        self->source_pos += self->last_len;

        if (CHAR(c) == '\n')
            ++i;
    }
    
    // Allocate memory for structures used during tokenization
    if (header)
	self->header_output = (char *) calloc(1, INITIAL_HEADER_SIZE);
    else
    {
	self->output_cols = (char **) malloc(self->num_cols * sizeof(char *));
	self->col_ptrs = (char **) malloc(self->num_cols * sizeof(char *));
	self->output_len = (int *) malloc(self->num_cols * sizeof(int));
	
	for (i = 0; i < self->num_cols; ++i)
	{
	    self->output_cols[i] = (char *) calloc(1, INITIAL_COL_SIZE);
            // Make each col_ptrs pointer point to the beginning of the
            // column string
	    self->col_ptrs[i] = self->output_cols[i];
	    self->output_len[i] = INITIAL_COL_SIZE;
	}
    }
    
    int done = 0;
    int repeat;
    self->state = START_LINE;
    
    // Loop until all of source has been read or we finish for some other reason
    while (self->source_pos - self->source < self->source_len && !done)
    {
	c = next_char(self); // next code point of input
	repeat = 1;
	
        // Keep parsing the same character
	while (repeat && !done)
	{
	    repeat = 0; // don't repeat by default; handling might change this

	    switch (self->state)
	    {
	    case START_LINE:
                if (CHAR(c) == '\n')
                    break;
                else if ((CHAR(c) == ' ' || CHAR(c) == '\t')
                         && self->strip_whitespace_lines)
                    break;
		else if (self->comment != 0 && c == self->comment)
		{
                    // comment line; ignore
		    self->state = COMMENT;
		    break;
		}
                // initialize variables for the beginning of line parsing
		col = 0;
		real_col = 0;
                BEGIN_FIELD();
		repeat = 1; // parse the same character again in mode START_FIELD
		break;
	    
	    case START_FIELD:
                // strip whitespace before field begins
		if ((CHAR(c) == ' ' || CHAR(c) == '\t') &&
                    self->strip_whitespace_fields)
		    ;
                else if (!self->strip_whitespace_lines && self->comment != 0 &&
                         c == self->comment)
                {
                    // comment line, not caught earlier because of no stripping
                    self->state = COMMENT;
                }
		else if (c == self->delimiter) // field ends before it begins
		{
		    END_FIELD();
                    BEGIN_FIELD();
		}
		else if (CHAR(c) == '\n')
		{
                    if (self->strip_whitespace_lines)
                    {
                        // Move on if the delimiter is whitespace, e.g.
                        // '1 2 3   '->['1','2','3']
                        if (self->delimiter == ' ' || self->delimiter == '\t')
                            ;
                        // Register an empty field if non-whitespace delimiter,
                        // e.g. '1,2, '->['1','2','']
                        else
                        {
                            END_FIELD();
                        }                            
                    }

                    else if (!self->strip_whitespace_lines)
                    {
                        // In this case we don't want to left-strip the field,
                        // so we backtrack
                        // TODO: fix this for unicode
                        /*char *tmp = self->source_pos;
                        --self->source_pos;

                        while (self->source_pos >= 0 &&
                               self->source[self->source_pos] != self->delimiter
                               && *self->source_pos != '\n')
                        {
                            --self->source_pos;
                        }

                        // backtracked to line beginning
                        if (self->source_pos == -1 || *self->source_pos
                                                                      == '\n')
                            self->source_pos = tmp;
                        else
                        {
                            ++self->source_pos;

                            if (self->source_pos == tmp)
                                // no whitespace, just an empty field
                                ;                                

                            else
                                while (self->source_pos < tmp)
                                {
                                    // append whitespace characters
                                    PUSH_CHAR(self->source[self->source_pos]);
                                    ++self->source_pos;
                                }

                            END_FIELD(); // whitespace counts as a field
                            }*/
                    }
                        
		    END_LINE();
		    self->state = START_LINE;
		}
		else if (c == self->quotechar) // start parsing quoted field
		    self->state = START_QUOTED_FIELD;
		else
		{
                    // Valid field character, parse again in FIELD mode
		    repeat = 1;
		    self->state = FIELD;
		}
		break;
		
	    case START_QUOTED_FIELD:
		if ((CHAR(c) == ' ' || CHAR(c) == '\t') &&
                    self->strip_whitespace_fields)
                    // ignore initial whitespace
		    ;
		else if (c == self->quotechar) // empty quotes
		{
		    END_FIELD();
		}
		else
		{
                    // Valid field character, parse again in QUOTED_FIELD mode
		    self->state = QUOTED_FIELD;
		    repeat = 1;
		}
		break;
		
	    case FIELD:
                if (self->comment != 0 && c == self->comment && whitespace && col == 0)
                {
                    // No whitespace stripping, but the comment char is found
                    // before any data, e.g. '  # a b c'
                    self->state = COMMENT;
                }
		else if (c == self->delimiter)
		{
                    // End of field, look for new field
		    END_FIELD();
                    BEGIN_FIELD();
		}
		else if (CHAR(c) == '\n')
		{
                    // Line ending, stop parsing both field and line
		    END_FIELD();
		    END_LINE();
		    self->state = START_LINE;
		}
		else
		{
                    // TODO: use a function is_whitespace to deal w/unicode whitespace
                    if (CHAR(c) != ' ' && CHAR(c) != '\t')
                        whitespace = 0; // field is not all whitespace
		    PUSH();
		}
		break;
		
	    case QUOTED_FIELD:
		if (c == self->quotechar) // Parse rest of field normally, e.g. "ab"c
		    self->state = FIELD;
		else if (CHAR(c) == '\n')
		    self->state = QUOTED_FIELD_NEWLINE;
		else
		{
		    PUSH();
		}
		break;

	    case QUOTED_FIELD_NEWLINE:
                // Ignore initial whitespace if strip_whitespace_lines and
                // newlines regardless
		if (((CHAR(c) == ' ' || CHAR(c) == '\t') &&
                     self->strip_whitespace_lines) || CHAR(c) == '\n')
		    ;
		else if (c == self->quotechar)
		    self->state = FIELD;
		else
		{
                    // Once data begins, parse it as a normal quoted field
		    repeat = 1;
		    self->state = QUOTED_FIELD;
		}
		break;
		
	    case COMMENT:
		if (CHAR(c) == '\n')
		    self->state = START_LINE;
		break; // keep looping until we find a newline
	    }
	}
	
        self->source_pos += self->last_len;
    }
    
    RETURN(0);
}

long str_to_long(tokenizer_t *self, char *str)
{
    errno = 0;
    char *tmp;
    long ret = strtol(str, &tmp, 0);

    if (tmp == str || *tmp != '\0')
 	self->code = CONVERSION_ERROR;
    else if (errno == ERANGE)
        self->code = OVERFLOW_ERROR;

    return ret;
}

double str_to_double(tokenizer_t *self, char *str)
{
    char *tmp;
    double ret = strtod(str, &tmp);

    if (tmp == str || *tmp != 0)
	self->code = CONVERSION_ERROR;
    else if (errno == ERANGE)
        self->code = OVERFLOW_ERROR;

    return ret;
}

void start_header_iteration(tokenizer_t *self)
{
    self->curr_pos = self->header_output;
}

void start_iteration(tokenizer_t *self, int col)
{
    // Begin looping over the column string with index col
    self->iter_col = col;
    // Start at the initial pointer position
    self->curr_pos = self->output_cols[col];
}

int _finished_iteration(tokenizer_t *self, char *buf, int len)
{
    // Iteration is finished if we've exceeded the length of the column string
    // or the pointer is at an empty byte
    return (self->curr_pos - buf >= len || *self->curr_pos == '\x00');
}

int finished_header_iteration(tokenizer_t *self)
{
    return _finished_iteration(self, self->header_output, self->header_len);
}

int finished_iteration(tokenizer_t *self)
{
    return _finished_iteration(self, self->output_cols[self->iter_col],
                               self->output_len[self->iter_col]);
}

char *next_field(tokenizer_t *self)
{
    char *tmp = self->curr_pos;

    // pass through the entire field until reaching the delimiter
    while (get_char(self, self->curr_pos) != 0)
	self->curr_pos += self->last_len;

    ++self->curr_pos; // next field begins after the delimiter
    if (*tmp == '\x01') // empty field; this is a hack
	return self->buf;
    else
	return tmp;
}

uint32_t next_char(tokenizer_t *self)
{
    return get_char(self, self->source_pos);
}

uint32_t get_char(tokenizer_t *self, char *buf)
{
    //TODO: avoid segfaults for invalid text files, handle malformed unicode
    int len = 4;
    unsigned char c = *buf;
    uint32_t ret = c & 0x07;

    if ((c & 0x80) == 0)
    {
        ret = c & 0x7F;
        len = 1;
    }
    else if ((c & 0xE0) == 0xC0)
    {
        ret = c & 0x1F;
        len = 2;
    }
    else if ((c & 0xF0) == 0xE0)
    {
        ret = c & 0x0F;
        len = 3;
    }

    int i;
    for (i = 1; i < len; ++i)
        ret = ((ret << 6) | (buf[i] & 0x3F));

    self->last_len = len;
    return ret;
}
