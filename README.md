# homeLab
This is my attempt to set up a home-lab in Docker. 
The environment variable SERVICE_ROOT has been added so that the root of the docker directory can be moved.

The final version will hopefully have the following characteristics:
  - Connecting via DynDNS connection from inside of the home to the outside
  - Get and maintain a certificate so that an SSL connection can be made
  - Use Obsidian as a method to maintain documentation and drive process
  - Use node.red connections between Obsidian and other programs
  - Use Elastic Search as a method of easily searching outside sources 
  - Use Mongo DB as a method of storing and retrieving large quantities of data
  - Added Calibre for managing ebooks
  - Added nextcloud for managing binary assets like photos and music
  - Added homebridge for compiled IoT major connections
  To preserve security of my system I will not publish my vaults. I will eventually include generic configuration information. 
