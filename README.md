=Usage=

Run from commandline to test

Set up as a Perl CGI script to use from calendar apps.

The /etc/youcal.conf file holds the configuration items.

You need to set up a sync user in Youtrack, and get an API token for it.

If this is running on a host with a timezone, set the tzid option.  Otherwise
leave it unset.

The filter option specifies which events to pull from Youtrack.  This should have some sort of time limit to prevent things going too far into the past.

The field-* options specify Youtrack custom fieldnames used for integration.

When linking to your calendar prgram, give the URL a query string of ?active=1 if you want to omit 
any change which is not yet submitted, not approved, or cancelled.

=Container=

This can be built as a container, using the very lightweight Apline linux base.  In this case, run with

docker run -p 80:80 \
  -e YOUCAL_URL=https://youtrack.smxemail.com/ \
  -e YOUCAL_TOKEN=perm:xxxxxxxxxxxx \
  --name youcal
  youcal

replace the token with an appropriate Youtrack API token

Alternatively, you can mount /etc/youcal as a volume and have a configuration file youcal.conf in there to hold the configuration rather than using environment variables.
