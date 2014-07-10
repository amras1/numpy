# Licensed under a 3-clause BSD style license - see LICENSE.rst

import numpy as np
from numpy import ma
import six
import os

cdef extern from "tokenizer.h":
    ctypedef enum tokenizer_state:
        START_LINE
        START_FIELD
        START_QUOTED_FIELD
        FIELD
        QUOTED_FIELD
        QUOTED_FIELD_NEWLINE
        COMMENT

    ctypedef enum err_code:
        NO_ERROR
        INVALID_LINE
        TOO_MANY_COLS
        NOT_ENOUGH_COLS
        CONVERSION_ERROR
        OVERFLOW_ERROR

    ctypedef struct tokenizer_t:
        char *source           # single string containing all of the input
        int source_len         # length of the input
        int source_pos         # current index in source for tokenization
        char delimiter         # delimiter character
        char comment           # comment character
        char quotechar         # quote character
        char *header_output    # string containing header data
        char **output_cols     # array of output strings for each column
        char **col_ptrs        # array of pointers to current output position for each col
        int *output_len        # length of each output column string
        int header_len         # length of the header output string
        int num_cols           # number of table columns
        int num_rows           # number of table rows
        int fill_extra_cols    # represents whether or not to fill rows with too few values
        tokenizer_state state  # current state of the tokenizer
        err_code code          # represents the latest error that has occurred
        int iter_col           # index of the column being iterated over
        char *curr_pos         # current iteration position
        char *buf              # buffer for misc. data
        int strip_whitespace_lines  # whether to strip whitespace at the beginning and end of lines
        int strip_whitespace_fields # whether to strip whitespace at the beginning and end of fields
        # Example input/output
        # --------------------
        # source: "A,B,C\n10,5.,6\n1,2,3"
        # output_cols: ["A\x0010\x001", "B\x005.\x002", "C\x006\x003"]

    tokenizer_t *create_tokenizer(char delimiter, char comment, char quotechar,
                                  int fill_extra_cols, int strip_whitespace_lines,
                                  int strip_whitespace_fields)
    void delete_tokenizer(tokenizer_t *tokenizer)
    int tokenize(tokenizer_t *self, int start, int end, int header,
                 int *use_cols, int use_cols_len)
    long str_to_long(tokenizer_t *self, char *str)
    double str_to_double(tokenizer_t *self, char *str)
    void start_iteration(tokenizer_t *self, int col)
    int finished_iteration(tokenizer_t *self)
    char *next_field(tokenizer_t *self)

class CParserError(Exception):
    """
    An instance of this class is thrown when an error occurs
    during C parsing.
    """

ERR_CODES = dict(enumerate([
    "no error",
    "invalid line supplied",
    "too many columns found in row"
    "not enough columns found in row"
    "type conversion error"
    ]))

cdef class CParser:
    """
    A fast Cython parser class which uses underlying C code
    for tokenization.
    """

    cdef:
        tokenizer_t *tokenizer
        int data_start
        int data_end
        object data_end_obj
        object include_names
        object exclude_names
        dict fill_values
        object fill_include_names
        object fill_exclude_names
        object fill_names
        int fill_extra_cols
        object use_cols

    cdef public:
        int width
        object names
        object source
        object header_start

    def __cinit__(self, source, strip_line_whitespace, strip_line_fields,
                  delimiter=',',
                  comment=None,
                  quotechar='"',
                  header_start=0,
                  data_start=1,
                  data_end=None,
                  names=None,
                  include_names=None,
                  exclude_names=None,
                  fill_values=('', '0'),
                  fill_include_names=None,
                  fill_exclude_names=None,
                  fill_extra_cols=0):

        if comment is None:
            comment = '\x00' # tokenizer ignores all comments if comment='\x00'
        self.tokenizer = create_tokenizer(ord(delimiter), ord(comment), ord(quotechar),
                                          fill_extra_cols,
                                          strip_line_whitespace,
                                          strip_line_fields)
        self.source = None
        self.setup_tokenizer(source)
        self.header_start = header_start
        self.data_start = data_start
        self.data_end = -1 # keep reading data until the end
        if data_end is not None and data_end >= 0:
            self.data_end = data_end
        self.data_end_obj = data_end
        self.names = names
        self.include_names = include_names
        self.exclude_names = exclude_names
        self.fill_values = get_fill_values(fill_values)
        self.fill_include_names = fill_include_names
        self.fill_exclude_names = fill_exclude_names
        self.fill_extra_cols = fill_extra_cols
    
    def __dealloc__(self):
        if self.tokenizer:
            delete_tokenizer(self.tokenizer) # perform C memory cleanup

    cdef raise_error(self, msg):
        err_msg = ERR_CODES.get(self.tokenizer.code, "unknown error")

        # error code is lambda function taking current line as input
        if callable(err_msg):
            err_msg = err_msg(self.tokenizer.num_rows + 1)

        raise CParserError("{0}: {1}".format(msg, err_msg))

    cdef setup_tokenizer(self, source):
        cdef char *src
        input = source

        if isinstance(input, six.string_types): # Filename
            file_obj = open(input)
            source = input.read()
            file_obj.close()
        else:
            source = input.read()
        # Create a reference to the Python object so its char * pointer remains valid
        source_str = source + '\n' # add newline to simplify handling last line of data
        self.source = source_str.encode('UTF-8') # encode in UTF-8 for char * handling
        src = self.source
        self.tokenizer.source = src
        self.tokenizer.source_len = len(self.source)

    def read_header(self):
        if self.names:
            self.width = len(self.names)

        # header_start is a valid line number
        elif self.header_start is not None and self.header_start >= 0:
            if tokenize(self.tokenizer, self.header_start, -1, 1, <int *> 0, 0) != 0:
                self.raise_error("an error occurred while tokenizing the header line")
            self.names = []
            name = ''
            for i in range(self.tokenizer.header_len):
                c = self.tokenizer.header_output[i] # next char in header string
                if not c: # zero byte -- field terminator
                    if name:
                        # replace empty placeholder with ''
                        self.names.append(name.replace('\x01', ''))
                        name = ''
                    else:
                        break # end of string
                else:
                    name += chr(c)
            self.width = len(self.names)

        else:
            # Get number of columns from first data row
            if tokenize(self.tokenizer, 0, -1, 1, <int *> 0, 0) != 0:
                self.raise_error("an error occurred while tokenizing the first line of data")
            self.width = 0
            for i in range(self.tokenizer.header_len):
                # zero byte -- field terminator
                if not self.tokenizer.header_output[i]:
                    # ends valid field
                    if i > 0 and self.tokenizer.header_output[i - 1]:
                        self.width += 1
                    else: # end of line
                        break
            if self.width == 0: # no data
                raise core.InconsistentTableError('No data lines found, C reader '
                                            'cannot autogenerate column names')
            # auto-generate names
            self.names = []
            for i in range(self.width):
                self.names.append('col{0}'.format(i + 1))

        # "boolean" array denoting whether or not to use each column
        self.use_cols = np.ones(self.width, np.intc)
        if self.include_names is not None:
            for i, name in enumerate(self.names):
                if name not in self.include_names:
                    self.use_cols[i] = 0
        if self.exclude_names is not None:
            for name in self.exclude_names:
                try:
                    self.use_cols[self.names.index(name)] = 0
                except ValueError: # supplied name is invalid, ignore
                    continue

        # self.names should only contain columns included in output
        copy = []
        for i, should_use in enumerate(self.use_cols):
            if should_use:
                copy.append(self.names[i])
        self.names = copy
        self.width = len(self.names)
        self.tokenizer.num_cols = self.width
            
    def read(self, try_int, try_float, try_string):
        if tokenize(self.tokenizer, self.data_start, self.data_end, 0,
                    <int *> self.use_cols.data, len(self.use_cols)) != 0:
            self.raise_error("an error occurred while tokenizing data")
        elif self.tokenizer.num_rows == 0: # no data
            return [[]] * self.width
        self._set_fill_names()
        return self._convert_data(try_int, try_float, try_string)

    cdef _set_fill_names(self):
        self.fill_names = set(self.names)
        if self.fill_include_names is not None:
            self.fill_names.intersection_update(self.fill_include_names)
        if self.fill_exclude_names is not None:
            self.fill_names.difference_update(self.fill_exclude_names)

    cdef _convert_data(self, try_int, try_float, try_string):
        cdef int num_rows
        num_rows = self.tokenizer.num_rows
        if self.data_end_obj is not None and self.data_end_obj < 0:
            # e.g. if data_end = -1, ignore the last row
            num_rows += self.data_end_obj
        cols = {}

        for i, name in enumerate(self.names):
            # Try int first, then float, then string
            try:
                if try_int and not try_int[name]:
                    raise ValueError()
                cols[name] = self._convert_int(i, num_rows)
            except ValueError:
                try:
                    if try_float and not try_float[name]:
                        raise ValueError()
                    cols[name] = self._convert_float(i, num_rows)
                except ValueError:
                    if try_string and not try_string[name]:
                        raise ValueError('Column {0} failed to convert'.format(name))
                    cols[name] = self._convert_str(i, num_rows)

        return cols

    cdef _convert_int(self, int i, int num_rows):
        col = np.empty(num_rows, dtype=np.int_)
        cdef long converted
        cdef int row
        row = 0
        cdef long *data
        data = <long *> col.data # pointer to raw data
        mask = set() # set of indices for masked values
        start_iteration(self.tokenizer, i) # begin the iteration process in C

        while not finished_iteration(self.tokenizer):
            if row == num_rows: # end prematurely if we aren't using every row
                break
            # retrieve the next field in a bytes value
            field = next_field(self.tokenizer)

            if field in self.fill_values:
                new_val = str(self.fill_values[field][0]).encode('utf-8')

                # Either this column applies to the field as specified in the 
                # fill_values parameter, or no specific columns are specified
                # and this column should apply fill_values.
                if (len(self.fill_values[field]) > 1 and self.names[i] in self.fill_values[field][1:]) \
                   or (len(self.fill_values[field]) == 1 and self.names[i] in self.fill_names):
                    mask.add(row)
                    # try converting the new value
                    converted = str_to_long(self.tokenizer, new_val)
                else:
                    converted = str_to_long(self.tokenizer, field)

            else:
                # convert the field to long (widest integer type)
                converted = str_to_long(self.tokenizer, field)

            if self.tokenizer.code in (CONVERSION_ERROR, OVERFLOW_ERROR):
                # no dice
                self.tokenizer.code = NO_ERROR
                raise ValueError()
            
            data[row] = converted
            row += 1

        if mask:
            # convert to masked_array
            param = []
            for i in range(row):
                if i in mask:
                    param.append(1)
                else:
                    param.append(0)
            return ma.masked_array(col, mask=param)
        else:
            return col

    cdef _convert_float(self, int i, int num_rows):
        col = np.empty(num_rows, dtype=np.float_)
        cdef double converted
        cdef int row
        row = 0
        cdef double *data
        data = <double *> col.data
        mask = set()

        start_iteration(self.tokenizer, i)
        while not finished_iteration(self.tokenizer):
            if row == num_rows:
                break
            field = next_field(self.tokenizer)
            if field in self.fill_values:
                new_val = str(self.fill_values[field][0]).encode('utf-8')
                if (len(self.fill_values[field]) > 1 and self.names[i] in self.fill_values[field][1:]) \
                   or (len(self.fill_values[field]) == 1 and self.names[i] in self.fill_names):
                    mask.add(row)
                    converted = str_to_double(self.tokenizer, new_val)
                else:
                    converted = str_to_double(self.tokenizer, field)
            else:
                converted = str_to_double(self.tokenizer, field)

            if self.tokenizer.code in (CONVERSION_ERROR, OVERFLOW_ERROR):
                self.tokenizer.code = NO_ERROR
                raise ValueError()
            else:
                data[row] = converted
            row += 1

        if mask:
            # convert to masked_array
            param = []
            for i in range(row):
                if i in mask:
                    param.append(1)
                else:
                    param.append(0)
            return ma.masked_array(col, mask=param)
        else:
            return col

    cdef _convert_str(self, int i, int num_rows):
        # similar to _convert_int, but no actual conversion
        col = np.empty(num_rows, dtype=object)
        cdef int row
        row = 0
        cdef int max_len
        max_len = 0 # greatest length of any element
        mask = set()

        start_iteration(self.tokenizer, i)
        while not finished_iteration(self.tokenizer):
            if row == num_rows:
                break
            field = next_field(self.tokenizer)
            if field in self.fill_values:
                el = str(self.fill_values[field][0])
                if (len(self.fill_values[field]) > 1 and self.names[i] in self.fill_values[field][1:]) \
                   or (len(self.fill_values[field]) == 1 and self.names[i] in self.fill_names):
                    mask.add(row)
                else:
                    el = field.decode('utf-8')
            else:
                el = field.decode('utf-8')
            # update max_len with the length of each field
            max_len = max(max_len, len(el))
            col[row] = el
            row += 1

        # convert to string with smallest length possible
        col = col.astype('|S{0}'.format(max_len))
        if mask:
            # convert to masked_array
            param = []
            for i in range(row):
                if i in mask:
                    param.append(1)
                else:
                    param.append(0)
            return ma.masked_array(col, mask=param)
        else:
            return col

def get_fill_values(fill_values, read=True):
    if len(fill_values) > 0 and isinstance(fill_values[0], six.string_types):
        # e.g. fill_values=('999', '0')
        fill_values = [fill_values]
    else:
        fill_values = fill_values
    try:
        # Create a dict with the values to be replaced as keys
        copy = []
        for l in fill_values:
            if read:
                copy.append((l[0].encode('utf-8'), l[1:]))
            else:
                copy.append((l[0], l[1:]))

    except IndexError:
        raise ValueError("Format of fill_values must be "
                         "(<bad>, <fill>, <optional col1>, ...)")
    return copy
