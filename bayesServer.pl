#!/usr/bin/perl -w

#bayesServer.pl uses a modified Bayesian algorithm, and tf-idf weighting
#for url classification, into classes defined during a training phase
#Train using -t class1.csv class2.csv..., or run as a server using 'portnumber'
#
#1/09/14
#Troy Daniels

use warnings;
use LWP::UserAgent;
use LWP::Protocol::https;
use File::Path;
use POSIX;
use IO::Select;
use IO::Socket;
use Fcntl;
use Tie::RefHash;

my %wordTally;      #hash containing running word tally for a given link type
my $totalWords;     #total number of words encountered for a given link type
my %globalTally;    #hash containing running global word tally
my $totalGlobal;    #global sum of words encountered
my %testTally;      #hash containing running word
my %totalTest;
my $path   = "./DataSets/LinkType/";    #path to link type datasets
my $global = "./DataSets/Global";       #path to global dataset

unless ( $#ARGV >= 0 ) {
    die
"Incorrect number of arguments.\nUse $0 -t class1.csv class2.csv... to train\nUse $0 'portnumber' to run as server\n";
}
if ( $ARGV[0] eq "-t" ) {
    shift(@ARGV);

    #create directory paths
    print "Creating directory paths\n";
    foreach my $file (@ARGV) {
        $file =~ /([^\.]*)/;    #For 'type.csv', 'type' becomes the class name
        my $class   = $1;
        my $linkDir = $path . $class . "/";
        $totalWords = 0;
        %wordTally  = ();
        eval { mkpath($linkDir) };
        warn "Can't create path $linkDir: $@" if $@;

        #test if data files exist for link class
        if ( -e $linkDir . $class ) {
            print
"Data for link type $class exits. Overwrite, Add  or Skip [O|A|S]?\n";
            while (<STDIN>) {
                chomp;
                if (/o/i) {
                    print "Overwriting $class data\n";
                    unlink( $linkDir . $class . "/" );   #rm existing class data
                    populate( $file, $totalWords, \%wordTally,
                        $linkDir . $class );
                    last;
                }
                elsif (/a/i) {
                    print "Adding to $class data\n";
                    tallyIn( $linkDir . $class, $totalWords, \%wordTally );
                    populate( $file, $totalWords, \%wordTally,
                        $linkDir . $class );
                    last;
                }
                elsif (/s/i) {
                    last;
                }
                else {
                    print
"Data for link type $class exists. Overwrite, Add or Skip [O|A|S]?\n";
                }
            }
        }
        else {
            print "Building $class data file\n";
            populate( $file, $totalWords, \%wordTally, $linkDir . $class );
        }
        updateGlobal($global);
    }
}
else {    #otherwise, act as a server file

    tallyIn( $global, \%globalTally );    #read in global data
    foreach $key ( keys %globalTally ) {
        $totalGlobal += $globalTally{$key};    #set $totalGlobal count
    }

    my $port = $ARGV[0];

    #auto flush socket
    $| = 1;

    #create socket
    my $server = new IO::Socket::INET(
        LocalHost => '0.0.0.0',
        LocalPort => $port,
        Proto     => 'tcp',
        Listen    => 10,
        Reuse     => 1
    );

    die "Can't open socket on port $port" unless $server;
    print "$0 waiting for client connection on port $port\n";

    # begin with empty buffers
    %inbuffer  = ();
    %outbuffer = ();
    %ready     = ();

    tie %ready, 'Tie::RefHash';

    nonblock($server);
    $select = IO::Select->new($server);

    # Main loop: check reads/accepts, check writes, check ready to process
    while (1) {
        my $client;
        my $rv;
        my $data;

        # check for new information on the connections we have
        # anything to read or accept?
        foreach $client ( $select->can_read(1) ) {
            if ( $client == $server ) {

                # accept a new connection
                $client = $server->accept();
                $select->add($client);
                nonblock($client);
            }
            else {
                # read data
                $data = '';
                $rv = $client->recv( $data, POSIX::BUFSIZ, 0 );
                unless ( defined($rv) && length $data ) {

                    # This would be the end of file, so close the client
                    delete $inbuffer{$client};
                    delete $outbuffer{$client};
                    delete $ready{$client};

                    $select->remove($client);
                    close $client;
                    next;
                }

                $inbuffer{$client} .= $data;

                # test whether the data in the buffer or the data we
                # just read means there is a complete request waiting
                # to be fulfilled.  If there is, set $ready{$client}
                # to the requests waiting to be fulfilled.
                while ( $inbuffer{$client} =~ s/(.*\n)// ) {
                    push( @{ $ready{$client} }, $1 );
                }
            }
        }

        # Any complete requests to process?
        foreach $client ( keys %ready ) {
            handle($client);
        }

        # Buffers to flush?
        foreach $client ( $select->can_write(1) ) {

            # Skip this client if we have nothing to say
            next unless exists $outbuffer{$client};

            $rv = $client->send( $outbuffer{$client}, 0 );

            unless ( defined $rv ) {
                warn "Unable to write to socket. Skipping.\n";
                next;
            }
            if ( $rv == length $outbuffer{$client} || $! == POSIX::EWOULDBLOCK )
            {
                substr( $outbuffer{$client}, 0, $rv ) = '';
                delete $outbuffer{$client} unless length $outbuffer{$client};
            }
            else {
                # Couldn't write all the data, and it wasn't because
                # it would have blocked.  Shutdown and move on.
                delete $inbuffer{$client};
                delete $outbuffer{$client};
                delete $ready{$client};

                $select->remove($client);
                close($client);
                next;
            }
        }

    }
}

# handle($socket) deals with all pending requests for $client
sub handle {

    # requests are in $ready{$client}
    # send output to $outbuffer{$client}
    my $client = shift;
    my $request;

    foreach $request ( @{ $ready{$client} } ) {

        # $request is the text of the request
        # put text of reply into $outbuffer{$client}
        %testTally = ();    #reset test tally and count
        chomp($request);

#(my $id, my $url)=split(',', $request);   #splt on comma to get unique id number
        if ( words( $request, \%testTally ) ) {    #parse page into words
            chomp($request);
            $outbuffer{$client} .= classify( \%testTally ) . "\n";
        }
        else {
            $outbuffer{$client} .= "403 or 404 page error\n";
        }
        print "Response sent\n";
    }
    delete $ready{$client};
}

# nonblock($socket) puts socket into nonblocking mode
sub nonblock {
    my $socket = shift;
    my $flags;

    $flags = fcntl( $socket, F_GETFL, 0 )
      or die "Can't get flags for socket: $!\n";
    fcntl( $socket, F_SETFL, $flags | O_NONBLOCK )
      or die "Can't make socket nonblocking: $!\n";
}

#$ classify (\%hash)
#returns a string denoting the class to which %hash data is believed to belong to
sub classify {
    ( my $hashRef ) = @_;
    my @classes = glob( $path . "*/*" );    #get all class data-sets
    my $bestClass;
    my $bestScore = 0;                      #reset bestScore
    foreach $class (@classes) {
        my $tempScore = 1;    #reset tempScore to 1 for multiplying
        %wordTally  = ();     #for each class, reset tally and count
        $totalWords = 0;
        tallyIn( $class, \%wordTally );
        foreach $key ( keys %wordTally ) {
            $totalWords += $wordTally{$key};    #set $totalWord count
        }
        foreach $word ( keys %{$hashRef} ) {
            if ( $wordTally{$word} ) {

                #next line defines heavily modified naive bayesian algorithm
                $tempScore +=
                  getWeight( $word, $class ) *
                  ( $wordTally{$word} * $totalGlobal ) /
                  ( $globalTally{$word} * $totalWords );
            }
        }
        if ( $tempScore > $bestScore ) {
            $bestClass = $class;
            $bestScore = $tempScore;
        }
    }

    #the next line uses the sigmoid function to give a degree of confidence
    my $sigmoid =
      1 / ( 1 + exp( ( -1 / ( .5 * $totalGlobal ) ) * $bestScore ) );
    $bestClass =~ /\/([^\.\/]*)[\.csv]?$/;
    return "$1,$sigmoid";
}

#$ getWeight($word, $class)
#returns the tf-idf weight of a given word
sub getWeight {
    my ( $word, $class ) = @_;
    if ( $wordTally{$word} && $globalTally{$word} ) {

        #the following line defines the tf-idf weighting
        $weight =
          log( 1 + $wordTally{$word} ) *
          log( $totalGlobal / $globalTally{$word} );
    }
    else {
        $weight = 0;
    }
    return $weight;
}

#void populate($urls, $counter, \%hash, $filename)
#generate word tally from $urls in %hash using $counter
sub populate {
    my ( $urls, $counter, $hashRef, $filename ) = @_;
    open URLsIn, "<", $urls or die $!;
    words( $_, $hashRef ) foreach (<URLsIn>);
    close URLsIn;
    tallyPrint( $filename, $counter, $hashRef );
}

#tallyIn($filename, \%hash)
#reads in data from $filename to %hash
sub tallyIn {
    my ( $filename, $hashRef ) = @_;
    open TALLY, "<", $filename or die $!;
    foreach my $line (<TALLY>) {
        chomp($line);
        ( my $key,       my $value )       = split( ' ', $line );
        ( my $numerator, my $denominator ) = split( '/', $value );
        $hashRef->{$key} += $numerator;
    }
    close TALLY;
}

#$ words($url, \%hash)
#gets words from $url page and stores a running tally in %hash
sub words {
    my ( $url, $hashRef ) = @_;

    #make request
    my $ua       = LWP::UserAgent->new;
    my $response = $ua->get( $_[0] );
    unless ( $response->is_success ) {
        print $response->status_line . " for $url\n";    # or whatever
        return 0;
    }

    #parse response
    $_ = $response->content;

    #remove html tags
    s/<[^<]*>/ /g;

    #remove strings containing non-alphabetical characters
    s/\w*([^\w\s]|\d|_)+\w* ?//g;

    #remove multiple spaces
    s/\s+/ /gs;

    #lowercase
    tr/A-Z/a-z/;
    chomp;

    #split on space
    my @strings = split(/ /);

    #tally results
    foreach (@strings) {    #do not include empty strings
        $hashRef->{$_}++ if $_;
    }
    return 1;
}

#void tallyPrint($filename, $counter, \%hash)
#prints %hash information to $filename, using $counter
sub tallyPrint {
    my ( $filename, $counter, $hashRef ) = @_;

    #total parsed words
    foreach ( keys %{$hashRef} ) {
        $counter += $hashRef->{$_};
    }
    open wordsOut, ">", $filename or die $!;

    #print to $filename
    foreach ( keys %{$hashRef} ) {
        print wordsOut "$_ $hashRef->{$_}/$counter \n" or die $!;
    }
    close wordsOut;
}

#void updateGlobal($filename)
#Updates global stats to $filename
sub updateGlobal {
    my $filename = @_;
    $totalGlobal = 0;    #reset counter and hash
    %globalTally = ();
    unlink $filename if -e $filename;    #rm ./DataSets/LinkType/Global
    my @files = glob( $path . "*/*" );
    foreach (@files) {
        tallyIn( $_, \%globalTally );
    }
    tallyPrint( $global, $totalGlobal, \%globalTally );
}

