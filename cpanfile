requires 'perl', '5.008001';

requires 'Plack';
requires 'URI';
requires 'AnyEvent';

on 'test' => sub {
    requires 'Test::More', '0.98';
};

