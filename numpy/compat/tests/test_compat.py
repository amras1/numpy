from os.path import join

from numpy.compat import isfileobj
from numpy.testing import TestCase, assert_
from numpy.testing.utils import tempdir


def test_isfileobj():
    with tempdir(prefix="numpy_test_compat_") as folder:
        filename = join(folder, 'a.bin')

        with open(filename, 'wb') as f:
            assert_(isfileobj(f))

        with open(filename, 'ab') as f:
            assert_(isfileobj(f))

        with open(filename, 'rb') as f:
            assert_(isfileobj(f))