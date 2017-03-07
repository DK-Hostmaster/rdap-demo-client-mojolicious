#!/usr/bin/env perl

use Mojolicious::Lite;                      # Ref: https://metacpan.org/pod/Mojolicious::Lite
use Mojo::UserAgent;                        # Ref: https://metacpan.org/pod/Mojo::UserAgent
use CHI;                                    # Ref: https://metacpan.org/pod/CHI
use Cwd; # getcwd                           # Ref: https://metacpan.org/pod/Cwd
use Readonly;                               # Ref: https://metacpan.org/pod/Readonly
use Mojo::JSON qw(decode_json encode_json); # Ref: https://metacpan.org/pod/Mojo::JSON
use HTTP::Date; # str2time                  # Ref: https://metacpan.org/pod/HTTP::Date
use Data::Dumper;                           # Ref: https://metacpan.org/pod/Data::Dumper
use Locale::Codes::Country; # code2country  # Ref: https://metacpan.org/pod/distribution/Locale-Codes/lib/Locale/Country.pm
use JSON::PP qw();                          # Ref: https://metacpan.org/pod/JSON::PP

our $VERSION = '0.0.1';

# Registration Data Access Protocol (RDAP)
# Ref: https://www.iana.org/protocols
# Bootstrap Service Registry for Domain Name Space 
# Ref: https://www.iana.org/assignments/rdap-dns/rdap-dns.xhtml

Readonly::Scalar my $iana_url => 'https://data.iana.org/rdap/dns.json';

# This list contains non-IANA registered RDAP servers (for test/evaluation etc.)
# Add your own 
Readonly::Array my @unregistered_entries => (
    { 
        countrycode => 'xx',
        url         => 'http://localhost:5000',
        label       => 'unregistered sandbox',
    },

);

Readonly::Array my @querytypes => (
    'nameserver',
);

# Mojolicious::Plugin::AssetPack
# Ref: https://metacpan.org/pod/Mojolicious::Plugin::AssetPack
plugin AssetPack => {
    pipes => [qw(Css JavaScript Combine)]
};

helper prettify_json => sub {
    my ($c, $json) = @_;

    my $coder = JSON::PP->new->pretty->allow_nonref;

    my $perl_scalar = $coder->decode( $json );

    return $coder->pretty->encode( $perl_scalar ); # pretty-printing
};

# Helper to resolve country name
helper get_countryname => sub {
    my ($c, $countrycode) = @_;

    my $country = code2country($countrycode);

    if ($country) {
        return $country;
    } else {
        return 'unknown';
    }
};

# Helper for setting Bootstrap panel colours
helper get_panel_heading => sub {
    my ($c, $panel) = @_;

    if ($c->stash($panel)) {
        return 'panel-danger';
    } else {
        return 'panel-success';    
    }
};

# Helper for getting error message based on a label
helper get_error => sub {
    my ($c, $key) = @_;

    if ($c->stash($key)) {
        return $c->stash($key);
    }
};

# Locating working directory, for cache establishment
my $working_dir = getcwd();

# Establishing root directory for file based cache
if (not -e "$working_dir/cache") {
    mkdir "$working_dir/cache" 
        or die "Unable to create directory: $working_dir/cache for cache: $!";
}

# Initiating cache
our $cache = CHI->new( driver => 'File',
    root_dir => "$working_dir/cache",
);

# Appliction root
get '/' => sub {
    my $self = shift;

    # Processings CSS assets:
    #   prism for code syntax highlighting ref: http://prismjs.com/index.html
    $self->asset->process(
        "app.css" => (
            "prism.css",
        )
    );

    # Processings JS assets:
    #   prism for code syntax highlighting ref: http://prismjs.com/index.html
    $self->asset->process(
        "app.js" => (
            "prism.js",
        )
    );

    # Starting actual request processing

    # Initializing UserAgent object
    my $ua  = Mojo::UserAgent->new;

    $self->app->log->info("Resolve IANA maintained RDAP resources from $iana_url");

    # Fetching possibly cached response from IANA
    my $json_response_from_iana = $cache->get($iana_url); 
    my $response_code_from_iana;

    # Cache hit!
    if ($json_response_from_iana) {
        $self->app->log->info('Cache hit! - we fetched the data from the cache');

    # Cache mis!    
    } else {
        $self->app->log->info('Cache miss! - we fetch the data from the designated URL: ', $iana_url);

        ($json_response_from_iana, $response_code_from_iana) = $self->_request({
            useragent         => $ua, 
            url               => $iana_url,
            sub_request_status => 'iana_sub_request_status', 
        });

        $self->app->log->info("Resolved IANA maintained RDAP resources from $iana_url");

        $self->app->log->debug('json_response_from_iana = ', Dumper $json_response_from_iana);
        $self->app->log->debug('response_code_from_iana = ', $response_code_from_iana || '');
    }

    # Converting the data to perl structure
    my $data_from_iana; 
    if ($json_response_from_iana) {
        $data_from_iana = decode_json($json_response_from_iana);
    }
    # The datastructure from IANA is array with arrays, so 
    # we restructurize to a key-value based structure so we do not 
    # have to iterate over lists every time we want to query data
    my $restructured_iana_data = {};
    foreach my $service (@{$data_from_iana->{services}}) {
        $restructured_iana_data->{$service->[0]->[0]} = {
            countrycode => $service->[0]->[0], # countrycode
            url         => $service->[1]->[0], # url
        };
    }

    # Append own entries for listing of RDAP resourses, this allows for 
    # development, experimentation etc. Please see the documentation (README.md)
    if (scalar @unregistered_entries) {
        foreach my $entry (@unregistered_entries) {
            $restructured_iana_data->{$entry->{countrycode}} = $entry;
        }
    }

    # Description of new structure a hash of hashes:
    # {
    #    <countrycode> -> {
    #       countrycode -> <countrycode>
    #       url         -> <url>
    #    } 
    # }

    # Converting parameters to reference to hash structure
    my $params = $self->req->params->to_hash;

    # Our canonical placeholders for parameters, please see parameter passing below
    # Please be aware that no parameter validation is taking place, since we want to 
    # emulate bad as well as good requests using this client
    my $countrycode = '';
    my $nameserver = '';
    my $querytype;

    if ($params->{nameserver}) {
        $nameserver = $params->{nameserver};
    }

    if ($params->{countrycode}) {
        $countrycode = $params->{countrycode};
    }

    if ($params->{querytype}) {
        $querytype = $params->{querytype};
    }

    # We now have enough information to do an actual request for data
    # towards a registrys RDAP interface

    my $json_response_from_registry;
    my $prettyfied_data_from_registry;
    my $response_code_from_registry;
    my $data_from_registry = {};
    my $registry_endpoint_url = '';

    # We got countrycode and possibly nameserver parameters, meaning our form got submitted
    if ($countrycode) {

        $self->app->log->info('Handle possible Registry request');

        $self->app->log->debug("received nameserver parameter: $nameserver");
        $self->app->log->debug("received countrycode parameter: $countrycode");

        my $registry_url = $restructured_iana_data->{$countrycode}->{url};

        $self->app->log->debug("Assembled registry URL: $registry_url");

        # Constructing URL based on parameter and designated endpoint
        # Example: 
        # URL: https://rdap.nic.cz/nameserver/
        # Querytype: nameserver
        # Nameserver: a.ns.nic.cz
        $registry_endpoint_url = $registry_url .'/'. $querytype .'/'. $nameserver;

        # Fetching possibly cached response from registry
        $json_response_from_registry = $cache->get($registry_endpoint_url);
        # Example registry JSON response:
        # {"handle": "a.ns.nic.cz", "links": [{"href": "https://rdap.nic.cz/nameserver/a.ns.nic.cz", "type": "application/rdap+json", "rel": "self", "value": "https://rdap.nic.cz/nameserver/a.ns.nic.cz"}], "ldhName": "a.ns.nic.cz", "rdapConformance": ["rdap_level_0"], "notices": [{"description": ["(c) 2015 CZ.NIC, z.s.p.o.\n\nIntended use of supplied data and information\n\nData contained in the domain name register, as well as information supplied through public information services of CZ.NIC association, are appointed only for purposes connected with Internet network administration and operation, or for the purpose of legal or other similar proceedings, in process as regards a matter connected particularly with holding and using a concrete domain name.\n"], "title": "Disclaimer"}], "objectClassName": "nameserver"}
    
        $self->app->log->info("Make query request towards registry RDAP resource using $registry_endpoint_url");

        # Cache hit!
        if ($json_response_from_registry) {
            $self->app->log->info("Cache hit! - we fetched the data from the cache for URL: $registry_endpoint_url");

        # Cache mis!    
        } else {
            $self->app->log->info("Cache miss! - we fetch the data from the URL: $registry_endpoint_url");

            # Fetching response from registry endpoint
            ($json_response_from_registry, $response_code_from_registry) = $self->_request({
                useragent         => $ua, 
                url               => $registry_endpoint_url,
                sub_request_status => 'registry_sub_request_status', 
            });

            $self->app->log->info("Handling query response from $registry_endpoint_url");

            $self->app->log->debug('json_response_from_registry = ', Dumper $json_response_from_registry);
            $self->app->log->debug('response_code_from_registry = ', $response_code_from_registry || '');
        }

        # Converting JSON data from registry to native data structure
        if ($json_response_from_registry) {
            $data_from_registry = decode_json($json_response_from_registry);
        }

    } else {
        my $error_message = 'Country code parameter not specified';
        $self->app->log->error($error_message);
        $self->stash('registry_sub_request_status' => $error_message);
    }

    my @countrycodes = keys %{$restructured_iana_data}; 

    # Render page
    $self->app->log->debug('Render page');

    $self->render('index',
        title                        => 'RDAP Demo Client',
        version                      => $VERSION,
        query                        => $countrycode,
        querytype                    => $querytype,
        querytypes                   => \@querytypes,
        nameserver                   => $nameserver, # nameserver parameter
        countrycode                  => $countrycode, # country code parameter
        json_response_from_iana      => $json_response_from_iana, # original JSON response
        countrycodes                 => \@countrycodes, # country codes
        json_response_from_registry  => $json_response_from_registry, # original JSON response
        data_from_iana               => $restructured_iana_data,
        data_from_registry           => $data_from_registry,
        registry_endpoint_url        => $registry_endpoint_url,
        iana_url                     => $iana_url,
    );
};

helper _request => sub {
    my ($self, $params) = @_;

    my $url                = $params->{url};
    my $ua                 = $params->{useragent};
    my $sub_request_status = $params->{sub_request_status};

    # Retrieving JSON data from designated URL
    my $response = $ua->get($url => { Accept => 'application/rdap+json' })->res;
    my $response_body;

    # Success
    if ($response->is_success) { 
        $self->app->log->info('Successfully fetched data, we populated the cache for key: ', $url);

        # Resolving expiration date, we use this for our cache
        my $expiration_date = $response->headers->expires;
        my $expiration_date_as_epoch = time + 86400; # we default to 24 hours

        # Converting to epoch to satisfy CHI API
        if ($expiration_date) {
            $expiration_date_as_epoch = str2time($expiration_date);
            $self->app->log->debug('expiration date: ', $response->headers->expires);
        }

        # Extract the actual body of the response (JSON)
        $response_body = $response->body;

        # Populate the cache, with the retrieved data, based on the expiration timestamp of the response
        # We use the URL as key
        $cache->set($url, $response_body, { expires_at => $expiration_date_as_epoch });

    # Error
    } elsif ($response->is_error)    { 
        my $error_message = 'Request did not succeed: ' . $response->{error}->{message} .' ('. $response->code .')';

        $self->app->log->error($error_message);

        my $error_label = $sub_request_status . '_error';
        my $error_label_code = $sub_request_status . '_code';

        $self->app->log->debug("stashing error message in: $error_label");
        $self->app->log->debug("stashing error code in: $error_label_code");

        $self->stash($error_label  => $error_message);
        $self->stash($error_label_code => $response->code);
        $self->stash($sub_request_status => 'Error');

        # Extract the actual body of the response (JSON)
        # if the registry responsed with something propagatable
        if ($response->body) {
            $response_body = $response->body;
        }

    # Redirect
    } elsif ($response->code and $response->code == 301) { 
        my $error_message = "We got redirected via URL: $url";
        $self->app->log->warn($error_message);
        my $error_label = $sub_request_status . '_warn';

        $self->app->log->debug("stashing error message in: $error_label");

        $self->stash($error_label => $error_message);

    # Everything else (we consider these as error for now)
    } else { 
        my $error_message = "Unable to handle response on request to $url: ". $response->{error}->{message};
        $self->app->log->error($error_message);
        $self->stash($sub_request_status  => $error_message);
    }

    # Returning the body of the original response object
    return ($response_body, $response->code);
};

app->start;

__DATA__

@@ index.html.ep
% layout 'default';

<!-- block for RDAP links information -->
<% my $links_block = begin %>
  % my $links = shift;
  % foreach my $link (@{$links}) {
    <p>href: <%= $link->{href} %></p>
    <p>rel: <%= $link->{rel} %></p>
    <p>type: <%= $link->{type} %></p>
    <p>value: <%= $link->{value} %></p>
  % }
<% end %>

<!-- block for RDAP notices information -->
<% my $notices_block = begin %>
  % my $notices = shift;
  % foreach my $notice (@{$notices}) {
    <p><h5><%= $notice->{title} %></h5></p>
    % foreach my $description (@{$notice->{description}}) {
        <p><%= $description %></p>
    % }
  % }
<% end %>

<!-- block for RDAP conformance information -->
<% my $rdapconformance_block = begin %>
  % my $rdapconformance = shift;
  % foreach my $conformance (@{$rdapconformance}) {
    <p><%= $conformance %></p>
  % }
<% end %>

<!-- IANA sub request error message and code if available -->
% if (my $error_message = get_error('iana_sub_request_error') and not get_error('iana_sub_request_status_error')) {
    <div class="alert alert-danger" role="alert"><%= $error_message %></div>
% }

<!-- Registry sub request error message and code if available -->
% if (my $error_message = get_error('registry_sub_request_status') and not get_error('registry_sub_request_status_error')) {
    <div class="alert alert-danger" role="alert"><%= $error_message %></div>
% }

<p>Demo client for the RDAP protocol. This client demonstrates fetching and caching the listing of available RDAP endpoints in the DNS
category and offers querying of these.</p>
<p>Please note that the registered endpoints including IANA are production endpoints, unless specified, and should be treated as such.</p> 
<p>All displayed data are presented under the respective disclaimers for the entities representing the endpoints.</p>

<!-- IANA sub request panel -->
<div class="panel <%= get_panel_heading('iana_sub_request_status') %>" id="iana_data">
  <div class="panel-heading">
    <h3 class="panel-title">Response from IANA</h3>
  </div>
  <div class="panel-body">
  <p>Request to: <code><%= $iana_url %></code></p>
  <p>For IANA RDAP bootstrap data for Domain Name System registrations</p>
  <p><i>Please note that the below list has been annotated with human readable country names, these are not part of the original data. Please see the actual response via the available link, which discloses all data.</i></p>
% if (my $error_message = get_error('iana_sub_request_status_error')) {
    <div class="alert alert-danger" role="alert"><%= $error_message %></div>
% }
% if (my $error_message = get_error('iana_sub_request_status_warn')) {
    <div class="alert alert-warning" role="alert_warn"><%= $error_message %></div>
% }

  </div>
  <table class="table table-striped table-condensed">
    <tr><th>Country</th><th>Country Code</th><th>URL</th></tr>
    % foreach my $c (sort keys %{$data_from_iana}) {
        % if (get_countryname($c) eq 'unknown') {
            <tr><td class="warning"><%= get_countryname($c) %> <%== '('.$data_from_iana->{$c}->{label}.')' if ($data_from_iana->{$c}->{label}); %></td><td class="warning"><%= uc($c) %><td class="warning"><%= $data_from_iana->{$c}->{url} %></tr>
        % } else {
            <tr><td><%= get_countryname($c) %> <%== '('.$data_from_iana->{$c}->{label}.')' if ($data_from_iana->{$c}->{label}); %></td><td><%= uc($c) %><td><%= $data_from_iana->{$c}->{url} %></tr>
        % }
    % }
  </table>
</div>

<p><button type="button" class="btn btn-link" id="hide_iana_response">Hide bootstrap JSON response</button> <button type="button" class="btn btn-link" id="show_iana_response">Show bootstrap JSON response</button></p>

<div id="iana_response">
<pre class="language-json"><code class="language-json"><%= prettify_json($json_response_from_iana) %></code></pre>
</div>

<br/>

<!-- Register query panel -->
<div class="panel panel-default">
  <div class="panel-heading">
    <h3 class="panel-title">Query Panel</h3>
  </div>
  <div class="panel-body">
<form action="/" method="GET">
    <div class="form-group">
    <label for="nameserver">Query</label>
    <input type="text" placeholder="Nameserver / Domain name / Entity identifyer" class="form-control" name="nameserver" />
    </div>

    <div class="form-group">
    <label for="querytype">Querytype</label>
    <select class="form-control" name="querytype">
    % foreach my $qt (sort @{$querytypes}) { 
        <option value="<%= $qt %>"><%= ucfirst $qt %></option>
    % } 
    </select>
    </div>

    <div class="form-group">
    <label for="countrycode">Country</label>
    <select class="form-control" name="countrycode">
    % foreach my $cc (sort @{$countrycodes}) {
        % if ($cc eq $countrycode) {
        <option value="<%= $cc %>" selected><%= get_countryname($cc) %> (<%= uc $cc %>)</option>
        % } else {
        <option value="<%= $cc %>"><%= get_countryname($cc) %> (<%= uc $cc %>)</option>
        % }
    % } 
    </select>
    </div>

    <button type="submit" class="btn btn-primary">Submit request</button> <button type="reset" id="reset_form" class="btn btn-default">Reset</button>
</form>

  </div>
</div>

<!-- Registry sub request panel -->
<div class="panel <%= get_panel_heading('registry_sub_request_status') %>" id="registry_data">
  <div class="panel-heading">
    <h3 class="panel-title">Response from: <%= get_countryname($countrycode) %> (<%= uc $countrycode %>)</h3>
  </div>
  <div class="panel-body">
  <p>Request to: <code><%= $registry_endpoint_url %></code></p>
  <p>For <%= $querytype %> value: <code><%= $nameserver %></code></p>
  <p><i>Please note, not all data have necessarily been mapped to the table below. Please see the actual response via the available link, which discloses all data.</i></p>
</i>
% if (my $error_message = get_error('registry_sub_request_status_error')) {
    <div class="alert alert-danger" role="alert"><%= $error_message %></div>
% }
% if (my $error_message = get_error('registry_sub_request_status_warn')) {
    <div class="alert alert-warning" role="alert_warn"><%= $error_message %></div>
% }

  </p>
  </div>
  <table class="table table-striped table-condensed">
    <tr><th>Key</th><th>Value</th></tr>
    <tr><td>objectClassName</td><td><%= $data_from_registry->{objectClassName} %></td></tr>
    <tr><td>ldhName</td><td><%= $data_from_registry->{ldhName} %></td></tr>
    <tr><td>unicodeName</td><td><%= $data_from_registry->{unicodeName} %></td></tr>
    <tr><td>handle</td><td><%= $data_from_registry->{handle} %></td></tr>
    <tr><td>links</td><td><%= $links_block->($data_from_registry->{links}) %></td></tr>
    <tr><td>notices</td><td><%= $notices_block->($data_from_registry->{notices}) %></td></tr>
    <tr><td>rdapConformance</td><td><%= $rdapconformance_block->($data_from_registry->{rdapConformance}) %></td></tr>
  </table>
</div>

<p><button type="button" class="btn btn-link" id="hide_registry_response">Hide registry JSON response</button> <button type="button" class="btn btn-link" id="show_registry_response">Show registry JSON response</button></p>

<div id="registry_response">
<pre class="language-json"><code class="language-json"><%= prettify_json($json_response_from_registry) %></code></pre>
</div>

@@ layouts/default.html.ep
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta http-equiv="X-UA-Compatible" content="IE=edge">
    <meta name="viewport" content="width=device-width, initial-scale=1">

    <!-- Bootstrap -->
    <!-- <link href="css/bootstrap.min.css" rel="stylesheet"> -->

    <!-- Latest compiled and minified CSS -->
    <link rel="stylesheet" href="https://maxcdn.bootstrapcdn.com/bootstrap/3.3.7/css/bootstrap.min.css" integrity="sha384-BVYiiSIFeK1dGmJRAkycuHAHRg32OmUcww7on3RYdg4Va+PmSTsz/K68vbdEjh4u" crossorigin="anonymous">

    <!-- Optional theme -->
    <link rel="stylesheet" href="https://maxcdn.bootstrapcdn.com/bootstrap/3.3.7/css/bootstrap-theme.min.css" integrity="sha384-rHyoN1iRsVXV4nD0JutlnGaslCJuC7uwjduW9SVrLvRYooPp2bWYgmgJQIXwl/Sp" crossorigin="anonymous">

    <!-- Latest compiled and minified JavaScript -->
    <script src="https://maxcdn.bootstrapcdn.com/bootstrap/3.3.7/js/bootstrap.min.js" integrity="sha384-Tc5IQib027qvyjSMfHjOMaLkfuWVxZxUPnCJA7l2mCWNIpG9mGCD8wGNIcPD7Txa" crossorigin="anonymous"></script>

    <!-- The above 3 meta tags *must* come first in the head; any other head content must come *after* these tags -->
    <title><%= title %></title>

    <!-- HTML5 shim and Respond.js for IE8 support of HTML5 elements and media queries -->
    <!-- WARNING: Respond.js doesn't work if you view the page via file:// -->
    <!--[if lt IE 9]>
      <script src="https://oss.maxcdn.com/html5shiv/3.7.3/html5shiv.min.js"></script>
      <script src="https://oss.maxcdn.com/respond/1.4.2/respond.min.js"></script>
    <![endif]-->  

    %= asset "app.js"
    %= asset "app.css"

  </head>
  <body>
    <div class="container-fluid">

        <h1><%= $title %> <small><%= $version %></small></h1>

        <%= content %>
    </div>

    <!-- jQuery (necessary for Bootstrap's JavaScript plugins) -->
    <script src="https://ajax.googleapis.com/ajax/libs/jquery/1.12.4/jquery.min.js"></script>
    <!-- Include all compiled plugins (below), or include individual files as needed -->
    <!-- <script src="js/bootstrap.min.js"></script> -->
    <script>
    $(document).ready(function(){

        // initial states of responses being hidden
        $("#iana_response").hide();
        $("#hide_iana_response").hide();

        $("#registry_response").hide();
        $("#hide_registry_response").hide();

        // we have a query, so we show registry response
        % if ($query) {
            $("#show_registry_response").show();
            $("#registry_data").show();    
    
        // we do not have a query so we hide the registry response
        % } else {
            $("#show_registry_response").hide();
            $("#registry_data").hide();
        % }

        // show/hide button handlers
        $("#hide_iana_response").click(function(){
            $("#iana_response").hide();
            $("#hide_iana_response").hide();
            $("#show_iana_response").show();
        });
        $("#show_iana_response").click(function(){
            $("#iana_response").show();
            $("#show_iana_response").hide();
            $("#hide_iana_response").show();
        });

        $("#hide_registry_response").click(function(){
            $("#registry_response").hide();
            $("#hide_registry_response").hide();
            $("#show_registry_response").show();
        });
        $("#show_registry_response").click(function(){
            $("#registry_response").show();
            $("#show_registry_response").hide();
            $("#hide_registry_response").show();
        });

        // reset form, please note this will trigger a warning on countrycode not being specified
        // we could append a country code, but again, the warning is perfectly okay
        $("#reset_form").click(function(){
            location = '/';
        });
    });
    </script>  
  </body>
</html>
