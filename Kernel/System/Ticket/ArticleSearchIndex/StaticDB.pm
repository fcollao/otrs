# --
# Kernel/System/Ticket/ArticleSearchIndex/StaticDB.pm - article search index backend static
# Copyright (C) 2001-2013 OTRS AG, http://otrs.com/
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file COPYING for license information (AGPL). If you
# did not receive this file, see http://www.gnu.org/licenses/agpl.txt.
# --

package Kernel::System::Ticket::ArticleSearchIndex::StaticDB;

use strict;
use warnings;

sub ArticleIndexBuild {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    for my $Needed (qw(ArticleID UserID)) {
        if ( !$Param{$Needed} ) {
            $Self->{LogObject}->Log( Priority => 'error', Message => "Need $Needed!" );
            return;
        }
    }

    my %Article = $Self->ArticleGet(
        ArticleID     => $Param{ArticleID},
        UserID        => $Param{UserID},
        DynamicFields => 0,
    );

    for my $Key (qw(From To Cc Subject)) {
        if ( $Article{$Key} ) {
            $Article{$Key} = $Self->_ArticleIndexString(
                String        => $Article{$Key},
                WordLengthMin => 3,
                WordLengthMax => 60,
            );
        }
    }
    for my $Key (qw(Body)) {
        if ( $Article{$Key} ) {
            $Article{$Key} = $Self->_ArticleIndexString(
                String => $Article{$Key},
            );
        }
    }

    # update search index table
    $Self->{DBObject}->Do(
        SQL  => 'DELETE FROM article_search WHERE id = ?',
        Bind => [ \$Article{ArticleID}, ],
    );

    # return if no content exists
    return 1 if !$Article{Body};

    # insert search index
    $Self->{DBObject}->Do(
        SQL => '
            INSERT INTO article_search (id, ticket_id, article_type_id,
                article_sender_type_id, a_from, a_to,
                a_cc, a_subject, a_body,
                incoming_time)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        Bind => [
            \$Article{ArticleID},    \$Article{TicketID}, \$Article{ArticleTypeID},
            \$Article{SenderTypeID}, \$Article{From},     \$Article{To},
            \$Article{Cc},           \$Article{Subject},  \$Article{Body},
            \$Article{IncomingTime},
        ],
    );

    return 1;
}

sub ArticleIndexDelete {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    for my $Needed (qw(ArticleID UserID)) {
        if ( !$Param{$Needed} ) {
            $Self->{LogObject}->Log( Priority => 'error', Message => "Need $Needed!" );
            return;
        }
    }

    # delete articles
    return if !$Self->{DBObject}->Do(
        SQL  => 'DELETE FROM article_search WHERE id = ?',
        Bind => [ \$Param{ArticleID} ],
    );

    return 1;
}

sub ArticleIndexDeleteTicket {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    for my $Needed (qw(TicketID UserID)) {
        if ( !$Param{$Needed} ) {
            $Self->{LogObject}->Log( Priority => 'error', Message => "Need $Needed!" );
            return;
        }
    }

    # delete articles
    return if !$Self->{DBObject}->Do(
        SQL  => 'DELETE FROM article_search WHERE ticket_id = ?',
        Bind => [ \$Param{TicketID} ],
    );

    return 1;
}

sub _ArticleIndexQuerySQL {
    my ( $Self, %Param ) = @_;

    if ( !$Param{Data} ) {
        $Self->{LogObject}->Log( Priority => 'error', Message => "Need Data!" );
        return;
    }

    # use also article table if required
    for (
        qw(
        From To Cc Subject Body
        ArticleCreateTimeOlderMinutes ArticleCreateTimeNewerMinutes
        ArticleCreateTimeOlderDate ArticleCreateTimeNewerDate
        )
        )
    {
        if ( $Param{Data}->{$_} ) {
            return ' INNER JOIN article_search art ON st.id = art.ticket_id ';
        }
    }

    return '';
}

sub _ArticleIndexQuerySQLExt {
    my ( $Self, %Param ) = @_;

    if ( !$Param{Data} ) {
        $Self->{LogObject}->Log( Priority => 'error', Message => "Need Data!" );
        return;
    }

    my %FieldSQLMapFullText = (
        From    => 'art.a_from',
        To      => 'art.a_to',
        Cc      => 'art.a_cc',
        Subject => 'art.a_subject',
        Body    => 'art.a_body',
    );
    my $SQLExt      = '';
    my $FullTextSQL = '';
    for my $Key ( sort keys %FieldSQLMapFullText ) {
        next if !$Param{Data}->{$Key};

        # replace * by % for SQL like
        $Param{Data}->{$Key} =~ s/\*/%/gi;

        # check search attribute, we do not need to search for *
        next if $Param{Data}->{$Key} =~ /^\%{1,3}$/;

        if ($FullTextSQL) {
            $FullTextSQL .= ' ' . $Param{Data}->{ContentSearch} . ' ';
        }

        # check if search condition extension is used
        if ( $Param{Data}->{ConditionInline} ) {
            $FullTextSQL .= $Self->{DBObject}->QueryCondition(
                Key          => $FieldSQLMapFullText{$Key},
                Value        => $Param{Data}->{$Key},
                SearchPrefix => $Param{Data}->{ContentSearchPrefix},
                SearchSuffix => $Param{Data}->{ContentSearchSuffix},
                Extended     => 1,
            );
        }
        else {

            my $Field = $FieldSQLMapFullText{$Key};
            my $Value = $Param{Data}->{$Key};

            if ( $Param{Data}->{ContentSearchPrefix} ) {
                $Value = $Param{Data}->{ContentSearchPrefix} . $Value;
            }
            if ( $Param{Data}->{ContentSearchSuffix} ) {
                $Value .= $Param{Data}->{ContentSearchSuffix};
            }

            # replace %% by % for SQL
            $Param{Data}->{$Key} =~ s/%%/%/gi;

            # replace * with % (for SQL)
            $Value =~ s/\*/%/g;

            # db quote
            $Value = lc $Self->{DBObject}->Quote( $Value, 'Like' );

            # Lower conversion is already done, don't use LOWER()/LCASE()
            $FullTextSQL .= " $Field LIKE '$Value'";
        }
    }
    if ($FullTextSQL) {
        $SQLExt = ' AND (' . $FullTextSQL . ')';
    }

    return $SQLExt;
}

sub _ArticleIndexString {
    my ( $Self, %Param ) = @_;

    if ( !defined $Param{String} ) {
        $Self->{LogObject}->Log( Priority => 'error', Message => "Need String!" );
        return;
    }

    my $Config = $Self->{ConfigObject}->Get('Ticket::SearchIndex::Attribute');
    my $WordCountMax = $Config->{WordCountMax} || 1000;

    # get words (use eval to prevend exits on damaged utf8 signs)
    my $ListOfWords = eval {
        $Self->_ArticleIndexStringToWord(
            String        => \$Param{String},
            WordLengthMin => $Param{WordLengthMin},
            WordLengthMax => $Param{WordLengthMax},
        );
    };
    return if !$ListOfWords;

    # find ranking of words
    my %List;
    my $IndexString = '';
    my $Count       = 0;
    WORD:
    for my $Word ( @{$ListOfWords} ) {
        $Count++;

        # only index the first 1000 words
        last if $Count > $WordCountMax;
        if ( $List{$Word} ) {
            $List{$Word}++;
            next WORD;
        }
        else {
            $List{$Word} = 1;
            if ($IndexString) {
                $IndexString .= ' ';
            }
            $IndexString .= $Word
        }
    }
    return $IndexString;
}

sub _ArticleIndexStringToWord {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    if ( !defined $Param{String} ) {
        $Self->{LogObject}->Log( Priority => 'error', Message => "Need String!" );
        return;
    }

    my $Config   = $Self->{ConfigObject}->Get('Ticket::SearchIndex::Attribute');
    my %StopWord = %{ $Self->{ConfigObject}->Get('Ticket::SearchIndex::StopWords') || {} };
    my @Filters  = @{ $Self->{ConfigObject}->Get('Ticket::SearchIndex::Filters') || [] };

    # get words
    my $LengthMin = $Param{WordLengthMin} || $Config->{WordLengthMin} || 3;
    my $LengthMax = $Param{WordLengthMax} || $Config->{WordLengthMax} || 30;
    my @ListOfWords;

    WORD:
    for my $Word ( split /\s+/, ${ $Param{String} } ) {

        # Apply filters
        for my $Filter (@Filters) {
            $Word =~ s/$Filter//g;
        }

        # convert to lowercase to avoid LOWER()/LCASE() in the DB query
        $Word = lc $Word;

        # only index words/strings within length boundaries
        my $Length = length $Word;
        if ( $Length < $LengthMin || $Length > $LengthMax ) {
            next WORD;
        }

        # Remove StopWords
        if ( $Word && $StopWord{$Word} ) {
            next WORD;
        }
        push @ListOfWords, $Word;
    }

    return \@ListOfWords;
}

1;
