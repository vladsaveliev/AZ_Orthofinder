from collections import namedtuple
from genericpath import isfile, isdir, exists
from os.path import join
import sys
from src import config


#class Option:
#    def __init__(self, dest, help, opts, default=None):
#        self.opts = opts
#        self.help = help
#        self.dest = dest
#        self.default = None
#        self.value = None
#
#
#class Bunch(object):
#    def __init__(self, adict):
#        self.__dict__.update(adict)
#
#
#class OptParser:
#    def __init__(self, description):
#        self.description = description
#        self.opts_by_dest = {}
#        self.opts_by_arg = {}
#
#    def add_argument(self, dest, help, opts, default=None, ):
#        self.opts_by_dest[dest] = Option(dest, help, opts, default)
#        self.
#
#    def help(self):
#        fst_col_width = max(len(' '.join(opt.args)) for opt in self.options)
#        res = self.description
#        for opt in self.options.itervalues():
#            res += '    ' + ' '.join(opt.opts).ljust(fst_col_width) + ': ' + opt.help + '\n'
#        return res
#
#    def parse(self, argv):
#        while argv:
#            arg = argv[0]
#            if arg not in self.options:
#
#
#            argv = argv[1:]
#        for arg in argv.split():
#
#        params = Bunch({dest:  self.options)


def add_common_arguments(op):
    op.add_argument('--start-from', dest='start_from', default=0)
    op.add_argument('--ask', '--ask-each-step', dest='ask_each_step', action='store_true', default=False, help='Wait for user to press ke every time before proceed to next step.')
    op.add_argument('-t', '--threads', dest='threads', default=0)
    op.add_argument('-j', '--jobs', dest='jobs', default=0)
    op.add_argument('-w', '--overwrite', dest='overwrite', action='store_true', default=False)
    op.add_argument('--min-length', dest='min_length', default=10)
    op.add_argument('--max-percent-stop', dest='max_percent_stop', default=20)
    op.add_argument('--evalue', dest='evalue', default=1e-5)
    op.add_argument('-d', '--debug', dest='debug', action='store_true', default=False)
    op.add_argument('--proxy', dest='proxy', default=None, help='Proxy for FTP, for example: --proxy 198.260.1.1:3333')

    op.usage += '''
    -j  Number of jobs to submit on cluster. Default is 30. Options used to submit:
        qsub -pe pe_smp 1 -S /bin/bash -cwd -j y -o intermediate/run_X.log -q batch.q

    -t  Use threads for BLAST instead of sumbitting jobs to cluster. Default is 30.

    --start-from
        Start from the specified step.
        Either name or number (see log.txt) or "uselog".
        If "uselog", the last "Done" record in log.txt will be searched.

    -w  Force to overwrite previous results and intermediate files in working directory.

Fine tuning:
    --min-length
        Minimum allowed length of proteins (default: 10)

    --max-percent_stop
        Maximum percent stop codons (default: 20)

    --evalue
        Blast e-value cut-off (default: 1e-5)
    '''

def check_common_args(params):
    if params.start_from == 'uselog':
        if not isfile(join(params.out_dir, config.log_fname)):
            arg_parse_error(
                'No %s in %s. Either check your path, or '
                'change the --start-from option' %
                (config.log_fname, params.out_dir))

    if params.start_from:
        params.overwrite = True


def arg_parse_error(msg, code=1):
    print >> sys.stderr, msg
    exit(code)


def check_file(fpath):
    if fpath and not isfile(fpath):
        arg_parse_error('File ' + fpath + ' does not exist or is a directory.')


def check_dir(dirpath):
    if dirpath:
        if not exists(dirpath):
            arg_parse_error('Directory ' + dirpath + ' does not exist.')
        if not isdir(dirpath):
            arg_parse_error(dirpath + ' is a file.')

