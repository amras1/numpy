import numpy as np
from numpy cimport ndarray
from numpy import ma
from distutils import version
import csv
import os
from libc.stdint cimport uint32_t
import sys

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
        char *source           # single unicode string containing all of the input
        int source_len         # length of the input
        char *source_pos       # current position in source for tokenization
        uint32_t delimiter     # delimiter character
        uint32_t comment       # comment character
        uint32_t quotechar     # quote character
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

    tokenizer_t *create_tokenizer(uint32_t delimiter, uint32_t comment, uint32_t quotechar,
                                  int fill_extra_cols, int strip_whitespace_lines,
                                  int strip_whitespace_fields)
    void delete_tokenizer(tokenizer_t *tokenizer)
    int tokenize(tokenizer_t *self, int header, int *use_cols, int use_cols_len,
                 int skip_header)
    long str_to_long(tokenizer_t *self, char *str)
    double str_to_double(tokenizer_t *self, char *str)
    void start_iteration(tokenizer_t *self, int col)
    void start_header_iteration(tokenizer_t *self)
    int finished_iteration(tokenizer_t *self)
    int finished_header_iteration(tokenizer_t *self)
    char *next_field(tokenizer_t *self)

class CParserError(Exception):
    """
    An instance of this class is thrown when an error occurs
    during C parsing.
    """

ERR_CODES = dict(enumerate([
    "no error",
    "invalid line supplied",
    lambda line: "too many columns found in line {0} of data".format(line),
    lambda line: "not enough columns found in line {0} of data".format(line),
    "type conversion error"
    ]))

cdef class CParser:
    """
    A fast Cython parser class which uses underlying C code
    for tokenization.
    """

    cdef:
        tokenizer_t *tokenizer
        int skip_header
        int skip_footer
        int has_header

    cdef public:
        object names
        bytes source
        int width
        ndarray use_cols

    def __cinit__(self, source, strip_line_whitespace, strip_line_fields,
                  delimiter=',',
                  comment=None,
                  quotechar='"',
                  skip_header=0,
                  skip_footer=0,
                  has_header=False,
                  names=None,
                  encoding='UTF-8'):

        if comment is None:
            comment = '\x00' # tokenizer ignores all comments if comment='\x00'
        if quotechar is None:
            quotechar = '\x00' # same here
        if delimiter is None:
            delimiter = ' ' # TODO: whitespace delimiting
        self.tokenizer = create_tokenizer(ord(delimiter), ord(comment), ord(quotechar),
                                          0,
                                          strip_line_whitespace,
                                          strip_line_fields)
        self.source = None
        self.setup_tokenizer(source, encoding)
        self.skip_header = skip_header
        self.skip_footer = skip_footer
        self.has_header = has_header
        self.names = names
    
    def __dealloc__(self):
        if self.tokenizer:
            delete_tokenizer(self.tokenizer) # perform C memory cleanup

    cdef raise_error(self, msg):
        err_msg = ERR_CODES.get(self.tokenizer.code, "unknown error")

        # error code is lambda function taking current line as input
        if callable(err_msg):
            err_msg = err_msg(self.tokenizer.num_rows + 1)

        raise CParserError("{0}: {1}".format(msg, err_msg))

    cpdef setup_tokenizer(self, source, encoding): #wait...this has to use encoding
        cdef char *src

        # Create a reference to the Python object so its char * pointer remains valid
        self.source = source + b'\n' # add newline to simplify handling last line of data
        src = self.source
        self.tokenizer.source = src
        self.tokenizer.source_len = len(self.source)

    def read_header(self):
        if tokenize(self.tokenizer, 1, <int *> 0, 0, self.skip_header) != 0:
            if self.has_header:
                self.raise_error("an error occurred while tokenizing the header line")
            else:
                self.raise_error("an error occurred while tokenizing the "
                                 "first line of data")
        names = []
        start_header_iteration(self.tokenizer)

        while not finished_header_iteration(self.tokenizer):
            name = next_field(self.tokenizer).decode('utf-8')
            try:
                names.append(name.encode())
            except UnicodeEncodeError:
                names.append(name)

        self.width = len(names)
        self.tokenizer.num_cols = self.width

        if self.has_header:
            self.names = names
        elif self.names is None:
            self.names = ['f{0}'.format(i) for i in range(self.width)]

    def read(self, dtypes):
        skip_rows = self.skip_header
        if self.has_header:
            skip_rows += 1
        if tokenize(self.tokenizer, 0, <int *> self.use_cols.data,
                    len(self.use_cols), skip_rows) != 0:
            self.raise_error("an error occurred while tokenizing data")
        elif self.tokenizer.num_rows == 0: # no data
            return [[]] * self.width #TODO: make this ndarray, warn
        return self._convert_data(dtypes)

    cdef _convert_data(self, dtypes):
        cdef int num_rows = self.tokenizer.num_rows
        cols = {}

        for i, name in enumerate(self.names):
            # Try int first, then float, then string
            try:
                if dtypes is not None and dtypes[i].kind != 'i':
                    raise ValueError()
                cols[name] = self._convert_int(i, num_rows, dtypes[i] if
                                               dtypes is not None else None)
            except ValueError:
                try:
                    if dtypes is not None and dtypes[i].kind != 'f':
                        raise ValueError()
                    cols[name] = self._convert_float(i, num_rows, dtypes[i] if
                                                     dtypes is not None else None)
                except ValueError:
                    if dtypes is not None and dtypes[i].kind != 'S': #TODO: handle unicode
                        raise ValueError('Column {0} failed to convert'.format(name))
                    cols[name] = self._convert_str(i, num_rows, dtypes[i] if
                                                   dtypes is not None else None)

        arr = np.zeros(num_rows, dtype=[(name.encode('utf-8'), cols[name].dtype)
                                        for name in self.names])
        for name in self.names:
            arr[name] = cols[name]

        return arr

    cdef ndarray _convert_int(self, int i, int num_rows, dtype):
        # intialize ndarray
        cdef ndarray col = np.empty(num_rows, dtype=dtype if dtype is not None
                                    else np.int_)
        cdef long converted
        cdef int row = 0
        cdef long *data = <long *> col.data # pointer to raw data
        cdef bytes field
        cdef bytes new_val
        mask = set() # set of indices for masked values
        start_iteration(self.tokenizer, i) # begin the iteration process in C

        while not finished_iteration(self.tokenizer):
            if row == num_rows: # end prematurely if we aren't using every row
                break
            # retrieve the next field in a bytes value
            field = next_field(self.tokenizer)

            if False:#field in self.fill_values:
                """    new_val = str(self.fill_values[field][0]).encode('utf-8')

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
                """
                pass
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
            return ma.masked_array(col, mask=[1 if i in mask else 0 for i in
                                              range(row)])
        else:
            return col

    cdef ndarray _convert_float(self, int i, int num_rows, dtype):
        # very similar to _convert_int()
        cdef ndarray col = np.empty(num_rows, dtype=dtype if dtype is not
                                    None else np.float_)
        cdef double converted
        cdef int row = 0
        cdef double *data = <double *> col.data
        cdef bytes field
        cdef bytes new_val
        mask = set()

        start_iteration(self.tokenizer, i)
        while not finished_iteration(self.tokenizer):
            if row == num_rows:
                break
            field = next_field(self.tokenizer)
            if False:#field in self.fill_values:
                """    new_val = str(self.fill_values[field][0]).encode('utf-8')
                if (len(self.fill_values[field]) > 1 and self.names[i] in self.fill_values[field][1:]) \
                   or (len(self.fill_values[field]) == 1 and self.names[i] in self.fill_names):
                    mask.add(row)
                    converted = str_to_double(self.tokenizer, new_val)
                else:
                    converted = str_to_double(self.tokenizer, field)
                """
                pass
            else:
                converted = str_to_double(self.tokenizer, field)

            if self.tokenizer.code in (CONVERSION_ERROR, OVERFLOW_ERROR):
                self.tokenizer.code = NO_ERROR
                raise ValueError()
            else:
                data[row] = converted
            row += 1

        if mask:
            return ma.masked_array(col, mask=[1 if i in mask else 0 for i in
                                              range(row)])
        else:
            return col

    cdef ndarray _convert_str(self, int i, int num_rows, dtype):
        # similar to _convert_int, but no actual conversion
        cdef ndarray col = np.empty(num_rows, dtype=dtype if dtype is not
                                    None else object)
        cdef int row = 0
        cdef bytes field
        cdef bytes new_val
        cdef int max_len = 0 # greatest length of any element
        mask = set()

        start_iteration(self.tokenizer, i)
        while not finished_iteration(self.tokenizer): #TODO: add skip_footer
            if row == num_rows:
                break
            field = next_field(self.tokenizer)
            if False:#field in self.fill_values:
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

        if dtype is not None:
            try:
                # convert to string with smallest length possible
                col = col.astype('S{0}'.format(max_len))
            except UnicodeEncodeError: # column contains chars outside range
                col = col.astype('U{0}'.format(max_len))
        if mask:
            return ma.masked_array(col, mask=[1 if i in mask else 0 for i in
                                              range(row)])
        else:
            return col

def get_fill_values(fill_values, read=True):
    """if len(fill_values) > 0 and isinstance(fill_values[0], six.string_types):
        # e.g. fill_values=('999', '0')
        fill_values = [fill_values]
    else:
        fill_values = fill_values
    try:
        # Create a dict with the values to be replaced as keys
        if read:
            fill_values = dict([(l[0].encode('utf-8'), l[1:]) for l in fill_values])
        else:
            # don't worry about unicode for writing
            fill_values = dict([(l[0], l[1:]) for l in fill_values])

    except IndexError:
        raise ValueError("Format of fill_values must be "
                         "(<bad>, <fill>, <optional col1>, ...)")"""
    return fill_values
